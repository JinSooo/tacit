package top.jinso.tacit.audio

import top.jinso.tacit.R
import android.content.Context
import android.os.Build
import android.util.AtomicFile
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.File
import java.util.UUID

internal object QnnCatalog {
    const val folder = "sherpa-onnx-qnn-SM8650-binary-30-seconds-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8"
    val archive = SpeechModelResource("model.tar.bz2",
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models-qnn-binary/$folder.tar.bz2",
        161991500, "8d050c08b01898b73144329be150cb4d4cc8802d72d6cae6add16e96fb7f0ef5")
    val files = listOf(
        SpeechModelResource("model.bin", "", 255995904, "f66bc5b70ce1d0c7c5abab3f45bbe59fdc266952ab6defc99d9864149ffd0098"),
        SpeechModelResource("tokens.txt", "", 315894, "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"))
    fun supported() = Build.VERSION.SDK_INT >= 31 && QnnPolicy.supported(Build.SOC_MODEL, Build.SUPPORTED_ABIS.toList())
    fun extract(archive: File, stage: File, cancel: ModelDownloadCancellation, resources: List<SpeechModelResource> = files) {
        val seen = mutableSetOf<String>()
        TarArchiveInputStream(BZip2CompressorInputStream(archive.inputStream().buffered())).use { tar ->
            while (true) {
                cancel.check()
                val entry = tar.nextEntry ?: break
                val resource = resources.find { entry.name == "$folder/${it.path}" } ?: continue
                require(entry.isFile && !entry.isSymbolicLink && !entry.isLink && entry.size == resource.bytes && seen.add(resource.path)) {
                    "加速模型压缩包格式不符"
                }
                SpeechModelDownload.copyVerified(tar, File(stage, resource.path), resource, cancel) { }
            }
        }
        require(seen == resources.map { it.path }.toSet()) { "加速模型文件不完整" }
    }
}

internal class QnnModels(private val context: Context) {
    private val root = File(context.noBackupFilesDir, "qnn-models").apply { mkdirs() }
    private val pointer = AtomicFile(File(root, "current"))
    @Synchronized fun current(): File? = runCatching {
        val name = pointer.readFully().toString(Charsets.UTF_8)
        require(Regex("[a-f0-9-]{36}").matches(name))
        File(root, name).takeIf { dir -> QnnCatalog.files.all { File(dir, it.path).length() == it.bytes } }
    }.getOrNull()
    fun download(cancel: ModelDownloadCancellation, progress: (Long, String) -> Unit): File {
        check(QnnCatalog.supported()) { "当前设备不支持本机加速" }
        // Model preparation is serialized by AudioRuntime.modelLock; retain the active and incoming dirs.
        val active = current()
        root.listFiles()?.filter { it.isDirectory && it != active && Regex("[a-f0-9-]{36}").matches(it.name) }
            ?.forEach { check(it.deleteRecursively()) { "无法清理上次未完成的加速模型" } }
        if (root.usableSpace < 480_000_000) throw SpeechModelProblem(R.string.acceleration_storage)
        val stage = SpeechModelDownload(listOf(QnnCatalog.archive)).prepare(root, cancel, progress)
        try {
            QnnCatalog.extract(File(stage, QnnCatalog.archive.path), stage, cancel)
            File(stage, QnnCatalog.archive.path).delete()
            return stage
        } catch (error: Throwable) { stage.deleteRecursively(); throw error }
    }
    fun activate(stage: File, cancel: ModelDownloadCancellation = ModelDownloadCancellation()): File =
        activatePreparedSpeechModels(stage, cancel, { dir ->
            check(QnnCatalog.supported()) { "当前设备不支持此加速模型" }
            // QNN may abort natively. Validation runs in :qnn, never in the recording/UI process.
            QnnClient(context, dir).use { it.validate() }
        }) { dir -> synchronized(this) {
            val old = current()
            val stream = pointer.startWrite()
            try { stream.write(dir.name.toByteArray()); pointer.finishWrite(stream) }
            catch (error: Throwable) { pointer.failWrite(stream); throw error }
            if (old != null && old != dir) runCatching { old.deleteRecursively() }
        } }
    /** Explicit synthetic-test staging, not a public import or an unverified pointer switch. */
    fun installStaged(): File {
        val incoming = File(root, "incoming")
        val stage = File(root, UUID.randomUUID().toString())
        check(incoming.renameTo(stage)) { "请先复制加速模型测试文件" }
        try {
            QnnCatalog.files.forEach { resource ->
                val file = File(stage, resource.path)
                require(file.length() == resource.bytes) { "加速模型大小不符" }
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                file.inputStream().use { input -> val buffer = ByteArray(65536); while(true) { val n=input.read(buffer); if(n<0)break;digest.update(buffer,0,n) } }
                require(digest.digest().joinToString(""){"%02x".format(it)} == resource.sha256) { "加速模型校验失败" }
            }
            return activate(stage)
        } catch(error: Throwable) { stage.deleteRecursively();throw error }
    }
}
