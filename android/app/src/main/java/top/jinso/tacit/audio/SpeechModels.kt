package top.jinso.tacit.audio

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
        // A killed download/import has no pointer. Remove only our orphan UUID directories.
        val active = current()
        root.listFiles()?.filter { it.isDirectory && it != active && Regex("[a-f0-9-]{36}").matches(it.name) }
            ?.forEach { it.deleteRecursively() }
    }
    @Synchronized fun current(): File? = runCatching {
        val name = String(pointer.readFully(), Charsets.UTF_8)
        require(Regex("[a-f0-9-]{36}").matches(name))
        File(root, name).takeIf { dir -> required.all { File(dir, it).isFile } }
    }.getOrNull()
    /** Stage all four resources, load real native sessions, then atomically switch one pointer. */
    fun import(tree: Uri): File {
        require(DocumentsContract.isTreeUri(tree)) { "请选择模型文件夹" }
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
                    id = requireNotNull(found) { "缺少模型文件：$path" }
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
        SpeechModelDownload().prepare(root, cancellation, progress)

    fun activate(stage: File, cancellation: ModelDownloadCancellation = ModelDownloadCancellation()): File =
        activatePreparedSpeechModels(stage, cancellation, { LocalSpeechEngine(it).use { engine -> engine.validate() } }) {
            synchronized(this) {
                val previous = current()
                val stream = pointer.startWrite()
                try {
                    stream.write(it.name.toByteArray())
                    pointer.finishWrite(stream)
                    check(current() == it) { "模型切换未完成，请检查存储空间后重试" }
                }
                catch (e: Throwable) { pointer.failWrite(stream); throw e }
                // Never delete another in-flight staging directory. Cleanup cannot invalidate a commit.
                if (previous != null && previous != it) runCatching { previous.deleteRecursively() }
            }
        }
    companion object {
        val required = listOf("sense-voice/model.int8.onnx", "sense-voice/tokens.txt", "silero_vad.onnx",
            "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")
    }
}

internal data class VoiceSegment(val start: Int, val samples: FloatArray, val vector: FloatArray)
internal class LocalSpeechEngine(private val dir: File) : AutoCloseable, SpeechEngine {
    private var vad: Vad? = null
    private var speaker: SpeakerEmbeddingExtractor? = null
    private var recognizer: OfflineRecognizer? = null
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
    fun validate() { vad(); speaker(); recognizer() }
    override fun segments(pcm: FloatArray): List<VoiceSegment> {
        val detector = vad(); detector.reset()
        val result = mutableListOf<VoiceSegment>()
        fun drain() {
            while (!detector.empty()) {
                val segment = detector.front(); detector.pop()
                if (segment.samples.size < SAMPLE_RATE / 2) continue
                val extractor = speaker(); val stream = extractor.createStream()
                try {
                    stream.acceptWaveform(segment.samples, SAMPLE_RATE); stream.inputFinished()
                    if (extractor.isReady(stream)) result += VoiceSegment(segment.start.toInt(), segment.samples,
                        AudioPolicy.unit(extractor.compute(stream)))
                } finally { stream.release() }
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
        return result.mapNotNull { segment ->
            val length = minOf(segment.samples.size, pcm.size - segment.start)
            if (length < SAMPLE_RATE / 2) null else segment.copy(samples = segment.samples.copyOf(length))
        }
    }
    override fun transcribe(samples: FloatArray): String {
        val asr = recognizer(); val stream = asr.createStream()
        return try {
            stream.acceptWaveform(samples, SAMPLE_RATE); asr.decode(stream)
            asr.getResult(stream).text.replace(Regex("<\\|[^|]*\\|>"), "").trim()
        } finally { stream.release() }
    }
    override fun close() { recognizer?.release(); speaker?.release(); vad?.release() }
}
