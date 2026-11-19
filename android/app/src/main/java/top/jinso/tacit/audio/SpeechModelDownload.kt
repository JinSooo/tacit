package top.jinso.tacit.audio

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletableFuture

internal data class SpeechModelResource(val path: String, val url: String, val bytes: Long, val sha256: String)

/** The four artifacts and hashes specified in docs/contracts.md; no archive or extra fp32 model download. */
internal object SpeechModelCatalog {
    private const val sense = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07"
    private const val release = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
    val resources = listOf(
        SpeechModelResource("sense-voice/model.int8.onnx", "$sense/model.int8.onnx", 239233841,
            "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
        SpeechModelResource("sense-voice/tokens.txt", "$sense/tokens.txt", 315894,
            "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
        SpeechModelResource("silero_vad.onnx", "$release/asr-models/silero_vad.onnx", 643854,
            "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"),
        SpeechModelResource("3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
            "$release/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx", 39593761,
            "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b")
    )
    val totalBytes = resources.sumOf { it.bytes }
}

enum class SpeechPreparationPhase { IDLE, DOWNLOADING, VALIDATING, IMPORTING, READY, CANCELLED, ERROR }
data class SpeechPreparationState(
    val phase: SpeechPreparationPhase = SpeechPreparationPhase.IDLE,
    val receivedBytes: Long = 0,
    val totalBytes: Long = SpeechModelCatalog.totalBytes,
    val message: String = "",
    val cancelling: Boolean = false
) {
    val busy get() = phase in setOf(SpeechPreparationPhase.DOWNLOADING, SpeechPreparationPhase.VALIDATING, SpeechPreparationPhase.IMPORTING)
    val canCancel get() = busy && phase != SpeechPreparationPhase.IMPORTING && !cancelling
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
        require(root.usableSpace >= resources.sumOf { it.bytes } + 32L * 1024 * 1024) { "空间不足，请至少腾出 314 MB 后重试" }
        val stage = File(root, UUID.randomUUID().toString())
        check(stage.mkdirs()) { "无法创建模型目录，请检查存储空间" }
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

    private fun transfer(resource: SpeechModelResource, target: File, cancellation: ModelDownloadCancellation,
        progress: (Long) -> Unit) {
        var url = URL(resource.url)
        repeat(6) {
            require(url.protocol == "https" && url.userInfo == null) { "模型下载地址必须使用 HTTPS" }
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
                    val location = connection.getHeaderField("Location") ?: throw IOException("模型下载重定向无效")
                    url = URL(url, location)
                } else {
                    if (status != 200) throw IOException("模型下载失败（HTTP $status），请稍后重试")
                    val length = connection.contentLengthLong
                    require(length < 0 || length == resource.bytes) { "模型大小与固定版本不符，请重试" }
                    connection.inputStream.use { copyVerified(it, target, resource, cancellation, progress) }
                    return
                }
            } finally {
                connection.disconnect()
                // Do not throw here: preserve the original error, or the outer cancellation check.
                runCatching { cancellation.attach(null) }
            }
        }
        throw IOException("模型下载重定向过多，请稍后重试")
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
                    require(total <= resource.bytes) { "模型大小与固定版本不符，请重试" }
                    digest.update(buffer, 0, n)
                    output.write(buffer, 0, n)
                    progress(total)
                }
                require(total == resource.bytes) { "模型下载不完整，请重试" }
                val hash = digest.digest().joinToString("") { "%02x".format(it) }
                require(hash == resource.sha256) { "模型 SHA-256 校验失败，请重新下载" }
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
