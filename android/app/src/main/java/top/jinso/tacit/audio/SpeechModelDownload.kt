package top.jinso.tacit.audio

import top.jinso.tacit.i18n.UiMessage
import top.jinso.tacit.R
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletionException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException

internal data class SpeechModelResource(
    val path: String, val url: String, val bytes: Long, val sha256: String,
    /** Tried in order after [url] fails, e.g. upstream after our release mirror. */
    val fallbackUrls: List<String> = emptyList(),
    /** Upstream re-exports verified to behave the same, as (bytes, sha256). */
    val alternates: List<Pair<Long, String>> = emptyList()
) {
    val maxBytes get() = alternates.maxOfOrNull { it.first }?.coerceAtLeast(bytes) ?: bytes
    fun acceptsSize(size: Long) = size == bytes || alternates.any { it.first == size }
    fun accepts(size: Long, hash: String) = (size == bytes && hash == sha256) || alternates.any { it.first == size && it.second == hash }
}

/** The four artifacts and hashes specified in docs/contracts.md; no archive or extra fp32 model download. */
internal object SpeechModelCatalog {
    private const val sense = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07"
    private const val release = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
    /** Unmodified copies on our own release, tried first so an upstream re-upload cannot block new installs. */
    const val mirror = "https://github.com/JinSooo/tacit/releases/download/models-v1"
    private const val speaker = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
    val resources = listOf(
        SpeechModelResource("sense-voice/model.int8.onnx", "$mirror/sense-voice-model.int8.onnx", 239233841,
            "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51", listOf("$sense/model.int8.onnx")),
        SpeechModelResource("sense-voice/tokens.txt", "$mirror/sense-voice-tokens.txt", 315894,
            "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc", listOf("$sense/tokens.txt")),
        SpeechModelResource("silero_vad.onnx", "$mirror/silero_vad.onnx", 643854,
            "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", listOf("$release/asr-models/silero_vad.onnx")),
        // Upstream re-exported this file on 2026-11-19; both versions give identical embeddings (cosine 1.000000).
        SpeechModelResource(speaker, "$mirror/$speaker", 39593761,
            "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b", listOf("$release/speaker-recongition-models/$speaker"),
            alternates = listOf(39593762L to "f1ee61be04000b50392a63442e5dd9feaea7e81dddd494d3647cf1c3d88a1498"))
    )
    val totalBytes = resources.sumOf { it.bytes }

    /** Optional music detector: without it recording works as before, it just cannot drop songs played elsewhere. */
    const val taggingFolder = "sherpa-onnx-ced-tiny-audio-tagging-2024-04-19"
    // GitHub, not Hugging Face: the latter is unreachable from mainland networks.
    val taggingArchive = SpeechModelResource("audio-tagging.tar.bz2",
        "$mirror/$taggingFolder.tar.bz2", 28531989,
        "84baf315b57d61aa69480c4fee878dab54cbc7be3e877db334e65d8b087e23c3", listOf("$release/audio-tagging-models/$taggingFolder.tar.bz2"))
    val tagging = listOf(
        SpeechModelResource("audio-tagging/model.int8.onnx", "", 6133417,
            "73aa22e783115f6a4ae169b36089907e07d0fd44795595eddea9c1bfc74cc945"),
        SpeechModelResource("audio-tagging/class_labels_indices.csv", "", 14675,
            "cdd1049833c4b86127c2773ac0d14a2754b6a6d0d1798002ed5c66e699708429"),
    )
}

/** Fetches the music detector archive and places its two verified files under `dir/audio-tagging` in one rename. */
internal fun installTagging(dir: File, cancellation: ModelDownloadCancellation = ModelDownloadCancellation()) =
    installTaggingWith(dir, SpeechModelCatalog.tagging, SpeechModelDownload(listOf(SpeechModelCatalog.taggingArchive)), cancellation)

internal fun installTaggingWith(dir: File, files: List<SpeechModelResource>, download: SpeechModelDownload,
    cancellation: ModelDownloadCancellation = ModelDownloadCancellation()) {
    // A process killed mid-download skips the finally below; only this unique worker stages inside dir.
    dir.listFiles()?.filter { it.isDirectory && Regex("[a-f0-9-]{36}").matches(it.name) }?.forEach { it.deleteRecursively() }
    val work = download.prepare(dir, cancellation) { _, _ -> }
    try {
        val unpacked = File(work, "audio-tagging").apply { mkdirs() }
        val wanted = files.associateBy { "${SpeechModelCatalog.taggingFolder}/${File(it.path).name}" }
        val seen = mutableSetOf<String>()
        TarArchiveInputStream(BZip2CompressorInputStream(File(work, SpeechModelCatalog.taggingArchive.path).inputStream().buffered())).use { tar ->
            while (true) {
                cancellation.check()
                val entry = tar.nextEntry ?: break
                val resource = wanted[entry.name] ?: continue
                require(entry.isFile && !entry.isSymbolicLink && !entry.isLink && entry.size == resource.bytes && seen.add(entry.name)) {
                    "音乐识别模型压缩包格式不符"
                }
                SpeechModelDownload.copyVerified(tar, File(unpacked, File(resource.path).name), resource, cancellation) { }
            }
        }
        require(seen == wanted.keys) { "音乐识别模型文件不完整" }
        val target = File(dir, "audio-tagging")
        target.deleteRecursively()
        check(unpacked.renameTo(target)) { "音乐识别模型保存失败" }
    } finally { work.deleteRecursively() }
}

/** Only model errors with deliberately authored copy are shown verbatim. */
internal class SpeechModelProblem(val label: Int) : IllegalArgumentException()

enum class SpeechPreparationPhase { IDLE, DOWNLOADING, VALIDATING, IMPORTING, READY, CANCELLED, ERROR }
internal data class SpeechPreparationState(
    val phase: SpeechPreparationPhase = SpeechPreparationPhase.IDLE,
    val receivedBytes: Long = 0,
    val totalBytes: Long = SpeechModelCatalog.totalBytes,
    val message: UiMessage? = null,
    val cancelling: Boolean = false
) {
    val busy get() = phase in setOf(SpeechPreparationPhase.DOWNLOADING, SpeechPreparationPhase.VALIDATING, SpeechPreparationPhase.IMPORTING)
    val canCancel get() = busy && phase != SpeechPreparationPhase.IMPORTING && !cancelling

    internal fun finished(error: Throwable?): SpeechPreparationState {
        var cause = error
        while (cause is ExecutionException || cause is CompletionException) cause = cause.cause
        val phase = when (cause) {
            null -> SpeechPreparationPhase.READY
            is CancellationException -> SpeechPreparationPhase.CANCELLED
            else -> SpeechPreparationPhase.ERROR
        }
        val message = when (cause) {
            null -> null
            is CancellationException -> UiMessage(R.string.model_cancelled)
            is java.net.SocketTimeoutException -> UiMessage(R.string.model_download_timeout)
            is java.net.UnknownHostException, is java.net.ConnectException -> UiMessage(R.string.model_download_unreachable)
            is SecurityException -> UiMessage(R.string.model_download_no_permission)
            is SpeechModelProblem -> UiMessage(cause.label)
            else -> UiMessage(R.string.model_preparation_failed)
        }
        return copy(phase = phase, message = message, cancelling = false)
    }
}

/** Cancellation and pointer commit share a lock, so an accepted cancellation can never activate. */
internal class ModelDownloadCancellation {
    @Volatile private var cancelled = false
    private var committed = false
    private var connection: HttpURLConnection? = null
    fun check() { if (cancelled) throw CancellationException("模型下载已取消") }
    @Synchronized fun attach(value: HttpURLConnection?) { check(); connection = value }
    fun cancel(): Boolean {
        val active = synchronized(this) {
            if (committed || cancelled) return false
            cancelled = true
            connection
        }
        // disconnect may wait on a socket; never block the UI thread.
        if (active != null) CompletableFuture.runAsync { active.disconnect() }
        return true
    }
    @Synchronized fun commit(action: () -> Unit) { check(); action(); committed = true }
}

/** Only anonymous HTTPS GETs of the fixed model URLs. Never receives audio, records or credentials. */
internal class SpeechModelDownload(
    private val resources: List<SpeechModelResource> = SpeechModelCatalog.resources,
    private val openConnection: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }
) {
    fun prepare(root: File, cancellation: ModelDownloadCancellation, progress: (Long, String) -> Unit): File {
        cancellation.check()
        if (root.usableSpace < resources.sumOf { it.maxBytes } + 32L * 1024 * 1024) throw SpeechModelProblem(R.string.model_storage)
        val stage = File(root, UUID.randomUUID().toString())
        if (!stage.mkdirs()) throw SpeechModelProblem(R.string.model_storage_write)
        try {
            var received = 0L
            for (resource in resources) {
                cancellation.check()
                progress(received, resource.path)
                val target = File(stage, resource.path).apply { parentFile!!.mkdirs() }
                transfer(resource, target, cancellation) { count -> progress(received + count, resource.path) }
                received += resource.bytes
            }
            cancellation.check()
            return stage
        } catch (error: Throwable) {
            stage.deleteRecursively()
            cancellation.check()
            throw error
        }
    }

    /** Tries each source in order; reports the last source's error when all fail. */
    private fun transfer(resource: SpeechModelResource, target: File, cancellation: ModelDownloadCancellation,
        progress: (Long) -> Unit) {
        var failure: Throwable? = null
        for (source in listOf(resource.url) + resource.fallbackUrls) {
            cancellation.check()
            try { return transferFrom(source, resource, target, cancellation, progress) }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { failure = error }
        }
        throw failure ?: SpeechModelProblem(R.string.model_download_failed)
    }

    private fun transferFrom(source: String, resource: SpeechModelResource, target: File, cancellation: ModelDownloadCancellation,
        progress: (Long) -> Unit) {
        var url = try { URL(source) } catch (_: java.net.MalformedURLException) { throw SpeechModelProblem(R.string.model_download_network) }
        repeat(6) {
            if (url.protocol != "https" || url.userInfo != null) throw SpeechModelProblem(R.string.model_download_network)
            cancellation.check()
            val connection = openConnection(url)
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 15000
                connection.readTimeout = 15000
                connection.useCaches = false
                connection.requestMethod = "GET"
                connection.setRequestProperty("Accept-Encoding", "identity")
                cancellation.attach(connection)
                val status = connection.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    val location = connection.getHeaderField("Location") ?: throw SpeechModelProblem(R.string.model_download_network)
                    url = try { URL(url, location) }
                    catch (_: java.net.MalformedURLException) { throw SpeechModelProblem(R.string.model_download_network) }
                } else {
                    if (status != 200) throw SpeechModelProblem(R.string.model_download_failed)
                    val length = connection.contentLengthLong
                    if (length >= 0 && !resource.acceptsSize(length)) throw SpeechModelProblem(R.string.model_size_invalid)
                    connection.inputStream.use { copyVerified(it, target, resource, cancellation, progress) }
                    return
                }
            } finally {
                connection.disconnect()
                // Do not throw here: preserve the original error, or the outer cancellation check.
                runCatching { cancellation.attach(null) }
            }
        }
        throw SpeechModelProblem(R.string.model_download_network)
    }

    companion object {
        internal fun copyVerified(input: InputStream, target: File, resource: SpeechModelResource,
            cancellation: ModelDownloadCancellation, progress: (Long) -> Unit) {
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            target.outputStream().use { output ->
                val buffer = ByteArray(65536)
                while (true) {
                    cancellation.check()
                    val n = input.read(buffer)
                    if (n < 0) break
                    cancellation.check()
                    total += n
                    if (total > resource.maxBytes) throw SpeechModelProblem(R.string.model_size_invalid)
                    digest.update(buffer, 0, n)
                    output.write(buffer, 0, n)
                    progress(total)
                }
                if (!resource.acceptsSize(total)) throw SpeechModelProblem(
                    if (total < resource.maxBytes) R.string.model_download_incomplete else R.string.model_size_invalid)
                val hash = digest.digest().joinToString("") { "%02x".format(it) }
                if (!resource.accepts(total, hash)) throw SpeechModelProblem(R.string.model_checksum_failed)
                cancellation.check()
                output.fd.sync()
            }
        }
    }
}

/** Shared by production installation and rollback tests. Native load must finish before commit. */
internal fun activatePreparedSpeechModels(stage: File, cancellation: ModelDownloadCancellation,
    validate: (File) -> Unit, activate: (File) -> Unit): File {
    try {
        cancellation.check()
        validate(stage)
        cancellation.commit { activate(stage) }
        return stage
    } catch (error: Throwable) {
        stage.deleteRecursively()
        throw error
    }
}

/** The audio worker serializes model replacement with transcription. The microphone service keeps capturing. */
internal fun replaceSpeechEngine(closeEngine: () -> Unit, resumeProcessing: () -> Unit, install: () -> Any?) {
    try {
        closeEngine()
        install()
    } finally {
        // On failure or cancellation the previous model is still active and can drain queued recordings.
        resumeProcessing()
    }
}
