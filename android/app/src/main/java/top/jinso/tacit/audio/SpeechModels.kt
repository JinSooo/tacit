package top.jinso.tacit.audio

import top.jinso.tacit.R
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.util.AtomicFile
import com.k2fsa.sherpa.onnx.*
import java.io.File
import java.util.UUID

internal class SpeechModels(private val context: Context) {
    private val root = File(context.noBackupFilesDir, "speech-models").apply { mkdirs() }
    private val pointer = AtomicFile(File(root, "current"))
    init {
        // A killed download/import has no pointer. Remove only our orphan UUID directories, and only once they sit
        // idle: another instance (the maintenance worker) may be downloading or validating into one right now.
        val active = current()
        root.listFiles()?.filter { it.isDirectory && it != active && Regex("[a-f0-9-]{36}").matches(it.name) &&
            abandonedStage(it) }?.forEach { it.deleteRecursively() }
    }
    @Synchronized fun current(): File? = runCatching {
        val name = String(pointer.readFully(), Charsets.UTF_8)
        require(Regex("[a-f0-9-]{36}").matches(name))
        File(root, name).takeIf { dir -> required.all { File(dir, it).isFile } }
    }.getOrNull()
    /** Stage all four resources, load real native sessions, then atomically switch one pointer. */
    fun import(tree: Uri): File {
        if (!DocumentsContract.isTreeUri(tree)) throw SpeechModelProblem(R.string.model_folder_required)
        val stage = File(root, UUID.randomUUID().toString()).apply { mkdirs() }
        try {
            for (path in required) {
                var id = DocumentsContract.getTreeDocumentId(tree)
                for (part in path.split('/')) {
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
                    var found: String? = null
                    context.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) if (cursor.getString(1) == part) {
                            require(found == null) { "模型目录有重名文件" }; found = cursor.getString(0)
                        }
                    }
                    id = found ?: throw SpeechModelProblem(R.string.model_folder_incomplete)
                }
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                val out = File(stage, path).apply { parentFile!!.mkdirs() }
                context.contentResolver.openInputStream(uri)!!.use { input ->
                    out.outputStream().use { output ->
                        val buffer = ByteArray(65536); var total = 0L
                        while (true) {
                            val n = input.read(buffer); if (n < 0) break
                            total += n; require(total <= 1_000_000_000L) { "模型文件过大" }
                            output.write(buffer, 0, n)
                        }
                        require(total > if (path.endsWith(".onnx")) 1024 else 10) { "模型文件为空或不完整" }
                        output.fd.sync()
                    }
                }
            }
            return activate(stage)
        } catch (e: Throwable) { stage.deleteRecursively(); throw e }
    }
    /** USB/debug installer stages only explicitly approved model resources here. */
    fun installStaged(): File {
        val incoming = File(root, "incoming")
        require(required.all { File(incoming, it).isFile && File(incoming, it).length() > 10 }) { "模型文件尚未复制完整" }
        val stage = File(root, UUID.randomUUID().toString())
        check(incoming.renameTo(stage)) { "模型安装失败" }
        return activate(stage)
    }
    fun download(cancellation: ModelDownloadCancellation, progress: (Long, String) -> Unit): File =
        SpeechModelDownload().prepare(root, cancellation, progress).also { stage ->
            // Best effort: a failed 6 MB extra never blocks the speech models; the maintenance job retries.
            runCatching { installTagging(stage, cancellation) }
                .onFailure { if (it is java.util.concurrent.CancellationException) throw it }
        }
    /** True when the installed models lack the music detector, so a background fetch is worthwhile. */
    fun taggingMissing(): Boolean = current()?.let { dir -> tagging.any { !File(dir, it).isFile } } == true
    fun supplementTagging() { current()?.let { installTagging(it) } }

    fun activate(stage: File, cancellation: ModelDownloadCancellation = ModelDownloadCancellation()): File =
        activatePreparedSpeechModels(stage, cancellation, { LocalSpeechEngine(it).use { engine -> engine.validate() } }) {
            synchronized(this) {
                val previous = current()
                val stream = pointer.startWrite()
                try {
                    stream.write(it.name.toByteArray())
                    pointer.finishWrite(stream)
                    if (current() != it) throw SpeechModelProblem(R.string.model_activation_failed)
                }
                catch (e: Throwable) { pointer.failWrite(stream); throw e }
                // Never delete another in-flight staging directory. Cleanup cannot invalidate a commit.
                if (previous != null && previous != it) runCatching { previous.deleteRecursively() }
            }
        }
    companion object {
        /** No file in the stage changed for an hour: a live download or validation always touches one sooner. */
        internal fun abandonedStage(dir: File, now: Long = System.currentTimeMillis()): Boolean =
            dir.walkTopDown().maxOf { it.lastModified() } < now - 60 * 60 * 1000L
        val required = listOf("sense-voice/model.int8.onnx", "sense-voice/tokens.txt", "silero_vad.onnx",
            "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")
        val tagging = SpeechModelCatalog.tagging.map { it.path }
    }
}

internal data class VoiceSegment(val start: Int, val samples: FloatArray, val vector: FloatArray)
private const val VOICEPRINT_CHUNK = 3 * SAMPLE_RATE
private const val TAGGING_WINDOW = 3 * SAMPLE_RATE
internal class LocalSpeechEngine(private val dir: File) : AutoCloseable, SpeechEngine {
    private var vad: Vad? = null
    private var speaker: SpeakerEmbeddingExtractor? = null
    private var recognizer: OfflineRecognizer? = null
    private var tagger: AudioTagging? = null
    private val taggingFiles = SpeechModels.tagging.map { File(dir, it) }
    private fun tagger() = tagger ?: if (!taggingFiles.all { it.isFile }) null else AudioTagging(config = AudioTaggingConfig(
        model = AudioTaggingModelConfig(ced = taggingFiles[0].path, numThreads = 1, debug = false, provider = "cpu"),
        labels = taggingFiles[1].path, topK = 10)).also { tagger = it }
    /** AudioSet probabilities for one span, or null when the optional music detector is not installed. */
    internal fun tags(samples: FloatArray): Map<Int, Float>? {
        val detector = runCatching { tagger() }.getOrNull() ?: return null
        // Like the voiceprint arena, ONNX memory follows input length; 3 s from the middle is enough to hear a song.
        val from = maxOf(0, (samples.size - TAGGING_WINDOW) / 2)
        val window = samples.copyOfRange(from, minOf(samples.size, from + TAGGING_WINDOW))
        val stream = detector.createStream()
        return try {
            stream.acceptWaveform(window, SAMPLE_RATE)
            detector.compute(stream, 10).associate { it.index to it.prob }
        } finally { stream.release(); window.fill(0f) }
    }
    /** Songs from another device's speaker pass VAD; they must not become voices or transcripts. */
    internal fun music(samples: FloatArray): Boolean = tags(samples)?.let(AudioPolicy::music) == true
    private fun vad() = vad ?: Vad(config = VadModelConfig(sileroVadModelConfig = SileroVadModelConfig(
        model = File(dir, "silero_vad.onnx").path, minSilenceDuration = .5f,
        minSpeechDuration = .5f, maxSpeechDuration = 5f))).also { vad = it }
    private fun speaker() = speaker ?: SpeakerEmbeddingExtractor(config = SpeakerEmbeddingExtractorConfig(
        model = File(dir, SpeechModels.required[3]).path, numThreads = 2, debug = false, provider = "cpu"))
        .also { speaker = it }
    private fun recognizer() = recognizer ?: OfflineRecognizer(config = OfflineRecognizerConfig(
        modelConfig = OfflineModelConfig(senseVoice = OfflineSenseVoiceModelConfig(
            model = File(dir, "sense-voice/model.int8.onnx").path, language = "auto"),
            tokens = File(dir, "sense-voice/tokens.txt").path, numThreads = 2, debug = false, provider = "cpu")))
        .also { recognizer = it }
    // Loading sessions validates model graph/schema; this never decodes user audio.
    fun validate() {
        try { vad(); speaker() } finally { finishAnalysis() }
        try { recognizer() } finally { finishTranscription() }
    }
    /**
     * The ONNX arena keeps its peak forever and grows with input length (30 s ≈ 600 MB, 3 s ≈ 100 MB), and
     * real VAD spans run past maxSpeechDuration (p95 13 s). Long spans are embedded in ≤3 s chunks and averaged.
     */
    internal fun voiceprint(samples: FloatArray): FloatArray? {
        if (samples.isEmpty()) return null
        val extractor = speaker()
        val chunks = (samples.size + VOICEPRINT_CHUNK - 1) / VOICEPRINT_CHUNK
        val size = (samples.size + chunks - 1) / chunks
        var sum: FloatArray? = null
        for (from in 0 until samples.size step size) {
            val stream = extractor.createStream()
            val chunk = samples.copyOfRange(from, minOf(samples.size, from + size))
            try {
                stream.acceptWaveform(chunk, SAMPLE_RATE); stream.inputFinished()
                if (!extractor.isReady(stream)) continue
                val v = AudioPolicy.unit(extractor.compute(stream))
                sum = sum?.also { acc -> v.indices.forEach { acc[it] += v[it] } } ?: v
            } finally { stream.release(); chunk.fill(0f) }
        }
        return sum?.let { AudioPolicy.unit(it) }
    }
    /** VAD spans clamped to the recording, before any music or voiceprint decision. */
    internal fun spans(pcm: FloatArray): List<Pair<Int, FloatArray>> {
        val detector = vad(); detector.reset()
        val result = mutableListOf<Pair<Int, FloatArray>>()
        fun drain() {
            while (!detector.empty()) {
                val segment = detector.front(); detector.pop()
                val start = segment.start.toInt()
                val length = minOf(segment.samples.size, pcm.size - start)
                if (length >= SAMPLE_RATE / 2) result += start to segment.samples.copyOf(length)
            }
        }
        var offset = 0
        while (offset < pcm.size) {
            val end = minOf(offset + 512, pcm.size)
            // Pad the last VAD frame, then clamp returned spans to actual recording length.
            val frame = FloatArray(512); pcm.copyInto(frame, 0, offset, end)
            detector.acceptWaveform(frame); drain(); offset = end
        }
        detector.flush(); drain()
        return result
    }
    override fun segments(pcm: FloatArray): List<VoiceSegment> = spans(pcm).mapNotNull { (start, samples) ->
        if (music(samples)) { samples.fill(0f); null }
        else voiceprint(samples)?.let { VoiceSegment(start, samples, it) }
    }
    override fun transcribe(samples: FloatArray): String {
        val asr = recognizer(); val stream = asr.createStream()
        return try {
            stream.acceptWaveform(samples, SAMPLE_RATE); asr.decode(stream)
            asr.getResult(stream).text.replace(Regex("<\\|[^|]*\\|>"), "").trim()
        } finally { stream.release() }
    }
    override fun finishTranscription() {
        recognizer?.release()
        recognizer = null
    }
    /** ONNX arenas retain their peak allocation until the session ends. */
    override fun finishAnalysis() {
        speaker?.release()
        speaker = null
        vad?.release()
        vad = null
        tagger?.release()
        tagger = null
    }
    internal val transcriberLoaded get() = recognizer != null
    internal val voiceprintLoaded get() = speaker != null
    override fun close() { finishAnalysis(); finishTranscription() }
}
