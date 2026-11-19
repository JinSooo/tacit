package top.jinso.tacit.audio

import android.app.Service
import android.content.Intent
import android.os.*
import com.k2fsa.sherpa.onnx.*
import java.io.File

/** Non-exported process boundary: upstream QNN can exit() on driver errors. No audio files or logs. */
class QnnService : Service() {
    private val thread = HandlerThread("tacit-qnn")
    private var recognizer: OfflineRecognizer? = null
    private lateinit var messenger: Messenger
    override fun onCreate() {
        super.onCreate(); thread.start()
        messenger = Messenger(Handler(thread.looper) { request ->
            val result = Bundle()
            try {
                when (request.what) {
                    LOAD -> {
                        check(QnnCatalog.supported())
                        val model = File(requireNotNull(request.data.getString("model"))).canonicalFile
                        val root = File(noBackupFilesDir, "qnn-models").canonicalFile
                        require(model.parentFile == root && Regex("[a-f0-9-]{36}").matches(model.name))
                        require(QnnCatalog.files.all { File(model, it.path).length() == it.bytes })
                        val libs = File(applicationInfo.nativeLibraryDir)
                        require(listOf("libQnnHtp.so", "libQnnSystem.so", "libQnnHtpV75Stub.so", "libQnnHtpV75Skel.so").all { File(libs,it).isFile })
                        recognizer?.release(); recognizer = null
                        OfflineRecognizer.prependAdspLibraryPath(libs.path)
                        recognizer = OfflineRecognizer(config = OfflineRecognizerConfig(modelConfig = OfflineModelConfig(
                            senseVoice = OfflineSenseVoiceModelConfig(language = "auto", useInverseTextNormalization = true,
                                qnnConfig = QnnConfig(backendLib = File(libs,"libQnnHtp.so").path,
                                    systemLib = File(libs,"libQnnSystem.so").path, contextBinary = File(model,"model.bin").path)),
                            tokens = File(model,"tokens.txt").path, provider = "qnn", debug = false)))
                        // A successful native decode proves execution, not just library discovery.
                        decode(FloatArray(16000))
                        result.putBoolean("ready", true)
                    }
                    DECODE -> {
                        request.data.classLoader = SharedMemory::class.java.classLoader
                        @Suppress("DEPRECATION") val memory = requireNotNull(request.data.getParcelable<SharedMemory>("pcm"))
                        val count = request.data.getInt("count")
                        require(count in 1..QnnPolicy.maxSamples && memory.size == count * 4)
                        val buffer = memory.mapReadOnly()
                        try {
                            val pcm = FloatArray(count); buffer.order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer().get(pcm)
                            try { result.putString("text", decode(pcm)) } finally { pcm.fill(0f) }
                        } finally { SharedMemory.unmap(buffer); memory.close() }
                    }
                    else -> error("Invalid request")
                }
            } catch (_: Exception) { result.putString("error", "加速模型加载或执行失败") }
            catch (_: LinkageError) { result.putString("error", "加速运行库不可用") }
            runCatching { request.replyTo.send(Message.obtain(null, request.what).apply { data = result }) }
            true
        })
    }
    private fun decode(pcm: FloatArray): String {
        val asr = checkNotNull(recognizer)
        val stream = asr.createStream()
        return try {
            stream.acceptWaveform(pcm, 16000); asr.decode(stream)
            asr.getResult(stream).text.replace(Regex("<\\|[^|]*\\|>"), "").trim()
        } finally { stream.release() }
    }
    override fun onBind(intent: Intent): IBinder = messenger.binder
    override fun onDestroy() {
        super.onDestroy()
        Handler(thread.looper).post { recognizer?.release(); recognizer = null; thread.quitSafely() }
    }
    companion object { const val LOAD = 1; const val DECODE = 2 }
}
