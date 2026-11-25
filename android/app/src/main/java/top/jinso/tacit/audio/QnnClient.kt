package top.jinso.tacit.audio

import android.content.*
import android.os.*
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Called only by the serialized audio worker; Binder callbacks never wait on that worker. */
internal class QnnClient(context: Context, private val models: File) : AutoCloseable {
    private val context = context.applicationContext
    private val connected = CountDownLatch(1)
    @Volatile private var remote: Messenger? = null
    @Volatile private var pending: CountDownLatch? = null
    @Volatile private var result: Bundle? = null
    @Volatile private var dead = false
    var ready = false; private set
    private val callbackThread = HandlerThread("tacit-qnn-result").apply { start() }
    private val replies = Messenger(Handler(callbackThread.looper) { message -> result = message.data; pending?.countDown(); true })
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) { remote = Messenger(binder); connected.countDown() }
        override fun onServiceDisconnected(name: ComponentName) { failed() }
        override fun onBindingDied(name: ComponentName) { failed() }
        override fun onNullBinding(name: ComponentName) { failed() }
    }
    private var bound = false
    private fun failed() { dead = true; ready = false; connected.countDown(); pending?.countDown() }
    fun validate() {
        check(Looper.myLooper() != Looper.getMainLooper()) { "请在后台准备语音模型" }
        if (!bound) {
            bound = context.bindService(Intent(context, QnnService::class.java), connection, Context.BIND_AUTO_CREATE)
            check(bound) { "无法启动本地加速服务" }
        }
        check(connected.await(20,TimeUnit.SECONDS) && !dead && remote != null) { "加速服务未就绪" }
        check(request(QnnService.LOAD, Bundle().apply { putString("model", models.path) }).getBoolean("ready")) { "加速模型尚未加载" }
        ready = true
    }
    fun transcribe(pcm: FloatArray): String {
        check(ready && !dead)
        require(pcm.size in 1..QnnPolicy.maxSamples)
        val memory = SharedMemory.create("tacit-speech", pcm.size * 4)
        try {
            val buffer = memory.mapReadWrite()
            try { buffer.order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer().put(pcm) }
            finally { SharedMemory.unmap(buffer) }
            check(memory.setProtect(OsConstants.PROT_READ))
            return request(QnnService.DECODE, Bundle().apply { putParcelable("pcm", memory);putInt("count",pcm.size) }).getString("text").orEmpty()
        } finally { memory.close() }
    }
    @Synchronized private fun request(kind: Int, data: Bundle): Bundle {
        if (dead) throw IOException("加速服务已停止")
        val wait = CountDownLatch(1); result = null; pending = wait
        try {
            requireNotNull(remote).send(Message.obtain(null,kind).apply { this.data = data;replyTo = replies })
            if (!wait.await(180,TimeUnit.SECONDS) || dead) { failed();throw IOException("加速执行中断，将改用普通转写") }
            val value = result ?: throw IOException("加速服务没有返回结果")
            value.getString("error")?.let { throw IOException(it) }
            return value
        } finally { pending = null }
    }
    override fun close() {
        failed()
        if (bound) { runCatching { context.unbindService(connection) };bound = false }
        callbackThread.quitSafely()
    }
}

// These diagnostic events also let device tests distinguish real acceleration from fallback.
internal const val QNN_UNAVAILABLE = "加速不可用，使用 CPU"
internal const val QNN_INTERRUPTED = "加速中断，使用 CPU"

internal class AcceleratedSpeechEngine(private val cpu: LocalSpeechEngine, private val context: Context,
    private val models: File?, private val changed: (String) -> Unit) : SpeechEngine, AutoCloseable {
    private var qnn: QnnClient? = null
    private var qnnAvailable = models != null && QnnCatalog.supported()
    init {
        changed(if (qnnAvailable) "NPU 模型已就绪，等待转写" else "使用 CPU")
    }
    private fun qnnForTranscription(): QnnClient? {
        qnn?.let { return it }
        if (!qnnAvailable) return null
        val candidate = QnnClient(context, checkNotNull(models))
        try {
            candidate.validate()
        } catch (error: Exception) {
            disableQnn(candidate, "validate", error, QNN_UNAVAILABLE)
            return null
        } catch (error: LinkageError) {
            disableQnn(candidate, "validate", error, QNN_UNAVAILABLE)
            return null
        }
        qnn = candidate
        changed("NPU 加速已启用")
        return candidate
    }
    override fun segments(pcm: FloatArray) = cpu.segments(pcm)
    override fun transcribe(samples: FloatArray): String {
        val active = qnnForTranscription() ?: return cpu.transcribe(samples)
        return try { QnnPolicy.transcribe(samples) { active.transcribe(it) } }
        catch (error: Exception) {
            disableQnn(active, "decode", error, QNN_INTERRUPTED)
            cpu.transcribe(samples)
        }
    }
    override fun finishAnalysis() = cpu.finishAnalysis()
    override fun finishTranscription() {
        qnn?.close()
        qnn = null
        cpu.finishTranscription()
    }
    /** Error class only: messages can carry paths, and nothing from a recording may reach logcat. */
    private fun disableQnn(client: QnnClient, stage: String, error: Throwable, status: String) {
        android.util.Log.w("TacitQnn", "NPU $stage failed: ${error.javaClass.simpleName}; using CPU")
        client.close()
        qnn = null
        qnnAvailable = false
        changed(status)
    }
    override fun close() { finishAnalysis(); finishTranscription() }
}
