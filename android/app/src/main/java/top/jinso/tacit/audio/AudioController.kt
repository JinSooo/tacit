package top.jinso.tacit.audio

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.Uri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import top.jinso.tacit.TacitApp
import top.jinso.tacit.core.Draft
import top.jinso.tacit.sync.AudioSync
import top.jinso.tacit.sync.Change
import top.jinso.tacit.sync.voiceprint
import java.time.Instant
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.util.concurrent.atomic.AtomicBoolean

/** All futures run off main. Observe completion on the UI dispatcher. Never call Future.get on UI. */
class AudioController(context: Context) {
    private val runtime = AudioRuntime.get(context)
    fun start(activity: Activity) {
        check(!activity.isFinishing && !activity.isDestroyed &&
            ((activity as? LifecycleOwner)?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED)
                ?: activity.hasWindowFocus())) { "请从可见页面启动录音" }
        check(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) { "请先允许麦克风权限" }
        check(runtime.allowed()) { "请先启用录音并取消暂停" }
        // Never runtime.lock on main: the worker holds it for seconds while it decrypts every file at first load.
        synchronized(runtime.control) {
            if (runtime.requested) return
            check(!runtime.recording) { "录音正在停止，请稍后重试" }
            runtime.requested = true; runtime.generation++
            try {
                activity.startForegroundService(Intent(activity, AudioRecorderService::class.java)
                    .putExtra("generation", runtime.generation))
            } catch (e: Exception) { runtime.requested = false; runtime.report("无法启动录音，请保持页面可见后重试"); throw e }
        }
    }
    fun stop(discardPending: Boolean = false) {
        synchronized(runtime.control) {
            if (!discardPending) runtime.app.prefs.audioCaptureWanted = false
            runtime.requested = false
            if(discardPending) runtime.generation++
        }
        runtime.context.stopService(Intent(runtime.context, AudioRecorderService::class.java))
        runtime.report("录音已停止")
    }
    /** Bumps whenever recordings, voices or status change; pages re-read on it instead of polling. */
    val changes: StateFlow<Long> get() = runtime.changes
    fun state() = AudioState(runtime.recording, runtime.models.current() != null, runtime.message)
    fun listClips(): CompletableFuture<List<AudioClip>> = runtime.submit {
        synchronized(runtime.lock) { runtime.queries.listClips() }
    }
    fun listConversations(): CompletableFuture<List<AudioConversation>> = runtime.submit {
        synchronized(runtime.lock) { runtime.queries.listConversations() }
    }
    fun renderTranscript(recordId: String, fallbackBody: String): CompletableFuture<String> = runtime.submit {
        synchronized(runtime.lock) { runtime.ledger.render(recordId, fallbackBody, runtime.macVoiceprint()) }
    }
    fun macVoiceKnown(): CompletableFuture<Boolean> = runtime.submit {
        synchronized(runtime.lock) { runtime.queries.macVoiceKnown() }
    }
    fun listSpeakers(includeIgnored: Boolean = false): CompletableFuture<List<AudioSpeaker>> = runtime.submit {
        synchronized(runtime.lock) { runtime.queries.listSpeakers(includeIgnored) }
    }
    fun markMe(id: String): CompletableFuture<Unit> {
        runtime.invalidatePolicy()
        return runtime.change { synchronized(runtime.lock) { runtime.ledger.markMe(id) }; runtime.drain() }
    }
    fun unmarkMe(id: String): CompletableFuture<Unit> {
        runtime.invalidatePolicy()
        return runtime.change { synchronized(runtime.lock) { runtime.ledger.unmarkMe(id) } }
    }
    fun renameSpeaker(id: String, name: String?): CompletableFuture<Unit> = runtime.change {
        synchronized(runtime.lock) { runtime.ledger.rename(id, name) }
    }
    fun setIgnored(id: String, ignored: Boolean): CompletableFuture<Unit> {
        runtime.invalidatePolicy()
        return runtime.change { synchronized(runtime.lock) { runtime.ledger.ignore(id, ignored) } }
    }
    fun ignore(id: String): CompletableFuture<Unit> = setIgnored(id, true)
    fun modelPreparation() = runtime.modelPreparation
    fun downloadModels(): CompletableFuture<Unit> = runtime.downloadModels()
    fun supportsNpu() = QnnCatalog.supported()
    fun accelerationState() = runtime.accelerationStatus
    fun downloadAcceleration(): CompletableFuture<Unit> = runtime.downloadAcceleration()
    fun cancelModelDownload() = runtime.cancelModelDownload()
    fun importModels(tree: Uri): CompletableFuture<Unit> = runtime.importModels { runtime.models.import(tree) }
    fun installStagedModels(): CompletableFuture<Unit> = runtime.importModels { runtime.models.installStaged() }
    fun prune(): CompletableFuture<Unit> = runtime.change {
        synchronized(runtime.lock) { runtime.store.prune(runtime.retentionDays()); runtime.store.sweep() }
    }
    /** Removes recordings and voiceprints; already saved History is managed by Vault/UI separately. */
    fun clearAudio(): CompletableFuture<Unit> {
        stop(discardPending = true); stopPlayback()
        return runtime.submit { synchronized(runtime.lock) { runtime.store.clear() }; runtime.report("录音和声纹已清理") }
    }
    /** Call before/with Vault deletion. Purges entire containing clip so backfill cannot recreate it. */
    fun deleteRecordAudio(recordId: String): CompletableFuture<Unit> {
        stop()
        stopPlayback()
        return runtime.change { synchronized(runtime.lock) { runtime.store.deleteRecord(recordId) } }
    }
    fun playSample(id: String): CompletableFuture<Unit> = runtime.submit {
        val pcm = synchronized(runtime.lock) {
            val span = requireNotNull(runtime.sample(id)) { "试听已过保留期" }
            val all = runtime.store.pcm(span.first)
            try { all.copyOfRange(span.second, span.third) } finally { all.fill(0f) }
        }
        try { runtime.play(pcm) } finally { pcm.fill(0f) }
    }
    fun stopPlayback() = runtime.stopPlayback()
}

internal class AudioRuntime private constructor(val context: Context) {
    val app = context.applicationContext as TacitApp
    /** Guards recordings and voices; the worker may hold it for seconds (first load decrypts every file). */
    val lock = Any()
    /** Guards only requested/generation and the recording start handshake; held for microseconds, safe on main. */
    val control = Any()
    val store = EncryptedAudioStore(context)
    val ledger = AudioLedger(store)
    val queries = AudioQueries(store, ledger, ::retentionDays, { sample(it) != null }, ::macVoiceprint)

    fun retentionDays(): Int = macPolicy()?.getInt("retention_days") ?: app.prefs.retentionDays
    private fun macPolicy() = app.vault.syncConnection()?.optJSONObject("audio")
    /** Caller holds [lock]. */
    fun macVoiceprint() = macPolicy()?.optJSONObject("voiceprint")?.voiceprint()

    fun applyMacAudio(audio: AudioSync, persist: () -> Unit) {
        synchronized(lock) {
            invalidatePolicy()
            store.applyRemoteCleanup(audio.retention, audio.purgeBefore?.let { Instant.parse(it).toEpochMilli() },
                audio.deleted.toSet(), app.vault::audioSourceRef)
            persist()
        }
        changed()
        schedule()
    }

    fun applyRecordChanges(page: List<Change>, deletes: List<Change.Delete>) = synchronized(lock) {
        invalidatePolicy()
        for (deletion in deletes) {
            store.deleteRecord(deletion.id) { clip -> app.vault.audioSourceRef(clip) == deletion.ref }
        }
        app.vault.applyChanges(page)
        changed()
    }

    val models = SpeechModels(context)
    val qnnModels = QnnModels(context)
    @Volatile var accelerationStatus = "使用 CPU"; private set
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "tacit-local-audio") }
    private val modelWorker = Executors.newSingleThreadExecutor { r -> Thread(r, "tacit-model-download") }
    private val modelLock = Any()
    private var modelCancellation: ModelDownloadCancellation? = null
    @Volatile var modelPreparation = SpeechPreparationState()
        private set

    private fun beginModelPreparation(phase: SpeechPreparationPhase): ModelDownloadCancellation = synchronized(modelLock) {
        check(!modelPreparation.busy) { "模型正在准备，请等待完成或取消下载" }
        ModelDownloadCancellation().also {
            modelCancellation = it
            modelPreparation = SpeechPreparationState(phase, message = if (phase == SpeechPreparationPhase.IMPORTING) "正在导入并验证模型" else "正在连接模型下载站点")
        }
    }
    fun cancelModelDownload() = synchronized(modelLock) {
        if (modelPreparation.canCancel && modelCancellation?.cancel() == true)
            modelPreparation = modelPreparation.copy(cancelling = true, message = "正在取消，现有模型保持可用")
    }
    private fun updateModelPreparation(phase: SpeechPreparationPhase, bytes: Long, message: String) = synchronized(modelLock) {
        modelPreparation = modelPreparation.copy(phase = phase, receivedBytes = bytes,
            message = if (modelPreparation.cancelling) "正在取消，现有模型保持可用" else message)
    }
    private fun modelFinished(error: Throwable?) = synchronized(modelLock) {
        var cause = error
        while (cause is ExecutionException || cause is CompletionException) cause = cause.cause
        val phase = when (cause) {
            null -> SpeechPreparationPhase.READY
            is CancellationException -> SpeechPreparationPhase.CANCELLED
            else -> SpeechPreparationPhase.ERROR
        }
        val message = when (cause) {
            null -> "本地语音模型已就绪"
            is CancellationException -> "已取消，未更换现有模型"
            is java.net.SocketTimeoutException -> "下载超时，请检查网络后重试"
            is java.net.UnknownHostException, is java.net.ConnectException -> "无法连接模型站点，请检查网络后重试，也可手动导入"
            is SecurityException -> "无法联网下载，请检查应用网络权限，也可手动导入"
            is IllegalArgumentException, is IllegalStateException, is java.io.IOException ->
                cause.message?.takeIf { it.any { char -> char in '\u4e00'..'\u9fff' } }
                    ?: "模型准备失败，请检查网络、存储空间和模型文件后重试"
            else -> "模型加载失败，现有模型保持可用，请重试或手动导入"
        }
        modelPreparation = modelPreparation.copy(phase = phase, message = message, cancelling = false)
        modelCancellation = null
    }
    fun downloadModels(): CompletableFuture<Unit> {
        val cancellation = beginModelPreparation(SpeechPreparationPhase.DOWNLOADING)
        return CompletableFuture.supplyAsync({
            val stage = models.download(cancellation) { bytes, path ->
                updateModelPreparation(SpeechPreparationPhase.DOWNLOADING, bytes, "正在下载 $path")
            }
            try {
                cancellation.check()
                updateModelPreparation(SpeechPreparationPhase.VALIDATING, SpeechModelCatalog.totalBytes, "下载校验通过，正在本机加载模型")
                // Only native load and pointer switch share the audio worker; network IO never blocks it.
                submit {
                    cancellation.check()
                    closeEngine()
                    models.activate(stage, cancellation)
                    report("本地语音模型已就绪")
                }.get()
            } catch (error: Throwable) {
                if (models.current() != stage) stage.deleteRecursively()
                throw error
            }
            schedule()
            Unit
        }, modelWorker).whenComplete { _, error -> modelFinished(error) }
    }
    fun downloadAcceleration(): CompletableFuture<Unit> {
        check(models.current() != null) { "请先准备语音模型" }
        check(QnnCatalog.supported()) { "此加速模型仅适用于骁龙 8 Gen 3（SM8650）" }
        val cancellation = beginModelPreparation(SpeechPreparationPhase.DOWNLOADING)
        synchronized(modelLock) { modelPreparation = modelPreparation.copy(totalBytes = QnnCatalog.archive.bytes) }
        return CompletableFuture.supplyAsync({
            val stage = qnnModels.download(cancellation) { bytes, _ ->
                updateModelPreparation(SpeechPreparationPhase.DOWNLOADING, bytes, "正在下载加速模型")
            }
            try {
                updateModelPreparation(SpeechPreparationPhase.VALIDATING, QnnCatalog.archive.bytes, "正在本机验证 NPU 加速")
                submit {
                    cancellation.check(); closeEngine()
                    qnnModels.activate(stage, cancellation)
                    accelerationStatus = "NPU 模型验证通过，等待处理录音"
                }.get()
            } catch (error: Throwable) {
                if (qnnModels.current() != stage) stage.deleteRecursively()
                throw error
            }
            schedule(); Unit
        }, modelWorker).whenComplete { _, error -> modelFinished(error) }
    }
    fun importModels(install: () -> java.io.File): CompletableFuture<Unit> {
        beginModelPreparation(SpeechPreparationPhase.IMPORTING)
        return submit {
            closeEngine()
            install()
            report("本地语音模型已就绪")
            schedule()
        }.whenComplete { _, error -> modelFinished(error) }
    }
    private val queued = AtomicBoolean(false)
    @Volatile var requested = false
    val changes = MutableStateFlow(0L)
    fun changed() = changes.update { it + 1 }
    @Volatile var recording = false
        set(value) { field = value; changed() }
    @Volatile var silenced = false
    @Volatile var generation = 0L
    private val policyRevisions = java.util.concurrent.atomic.AtomicLong()
    private val policyRevision get() = policyRevisions.get()
    @Volatile var message = "录音未启动"
    private var engine: AcceleratedSpeechEngine? = null
    private var player: AudioTrack? = null
    fun allowed() = app.prefs.enabled(AUDIO_SOURCE)
    fun invalidatePolicy() { policyRevisions.incrementAndGet() }
    fun report(text: String) { message = text; changed() }
    fun <T> submit(block: () -> T): CompletableFuture<T> = CompletableFuture.supplyAsync({
        try { block() } catch (e: Throwable) { report("本地音频处理失败，请检查模型、空间和权限后重试"); throw e }
    }, worker)
    /** For work that changes recordings or voices: signals pages even when the work fails halfway. */
    fun <T> change(block: () -> T): CompletableFuture<T> = submit { try { block() } finally { changed() } }
    fun closeEngine() { engine?.close(); engine = null; accelerationStatus = "使用 CPU" }
    /**
     * Called on the microphone thread. Encryption and disk writes happen on the worker so a slow write
     * can never stall AudioRecord and drop audio; the caller may reuse [pcm] as soon as this returns.
     */
    fun captured(pcm: ShortArray, start: Long, token: Long, final: Boolean = false) {
        if (token != generation || (!requested && !final) || !allowed()) return
        val copy = pcm.copyOf()
        submit {
            try {
                // A discard (generation bump) or pause queued after capture still wins.
                synchronized(lock) { if (token == generation && allowed()) store.add(copy, start) }
            } finally { copy.fill(0) }
            changed()
            schedule()
        }
    }
    fun schedule() {
        if (!queued.compareAndSet(false, true)) return
        submit {
            val policyAtStart = policyRevision
            var completed = false
            try { drain(); completed = true } finally {
                queued.set(false)
                // A new segment or Mac voiceprint can arrive while processing the current snapshot.
                if (completed && allowed() && models.current() != null && synchronized(lock) {
                        policyAtStart != policyRevision ||
                            store.clips().any { microphoneClip(it) && !it.getBoolean("analyzed") && store.exists(it.getString("id")) }
                    }) schedule()
            }
        }
    }
    fun drain() {
        val token = generation
        val (policy, voiceprint) = synchronized(lock) {
            val mac = macPolicy()
            store.prune(mac?.getInt("retention_days") ?: app.prefs.retentionDays)
            policyRevision to macVoiceprint()
        }
        if (!allowed()) return
        val dir = models.current() ?: run { report("录音已加密保存，等待准备本地模型"); return }
        val speech = engine ?: AcceleratedSpeechEngine(LocalSpeechEngine(dir), context, qnnModels.current()) { accelerationStatus = it }.also { engine = it }
        AudioProcessor(store, lock, speech, voiceprint).drain({ allowed() && token == generation && policy == policyRevision }) { p ->
            app.vault.ingest(Draft(source = AUDIO_SOURCE, title = "对话记录", body = p.body,
                start = p.start, end = p.end,
                sourceRef = "audio:${p.clipId}", method = "asr"), offset = p.offset)
        }
        report(when {
            silenced -> "麦克风正由其他应用使用，等待系统恢复"
            voiceprint == null && synchronized(lock) { store.speakers().none { it.optBoolean("me") } } -> "仅本地识别人声，等待标记“我”"
            recording -> "正在录音，本地转写中"
            else -> "本地音频处理完成"
        })
    }
    fun sample(id: String): Triple<String, Int, Int>? {
        for (clip in store.clips().asReversed()) for (u in clip.getJSONArray("utterances").objects()) {
            if (u.getString("speaker") == id && store.exists(clip.getString("id"))) {
                val start = u.getInt("start")
                return Triple(clip.getString("id"), start, minOf(clip.getInt("samples"), start + u.getInt("length"), start + SAMPLE_RATE * 10))
            }
        }
        return null
    }
    fun play(pcm: FloatArray) {
        val shorts = ShortArray(pcm.size) { (pcm[it].coerceIn(-1f, 1f) * 32767).toInt().toShort() }
        val track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(shorts.size * 2).build()
        synchronized(this) { stopPlayback(); player = track }
        try { track.write(shorts, 0, shorts.size); track.play() } finally { shorts.fill(0) }
    }
    @Synchronized fun stopPlayback() { player?.let { runCatching { it.stop() }; it.release() }; player = null }
    companion object {
        @Volatile private var instance: AudioRuntime? = null
        fun get(context: Context): AudioRuntime = instance ?: synchronized(this) {
            instance ?: AudioRuntime(context.applicationContext).also { instance = it }
        }
    }
}
