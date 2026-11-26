package top.jinso.tacit.audio

import top.jinso.tacit.i18n.UiMessage
import top.jinso.tacit.R
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
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.util.concurrent.atomic.AtomicBoolean

internal const val STORED_CONVERSATION_TITLE = "对话记录"

/** All futures run off main. Observe completion on the UI dispatcher. Never call Future.get on UI. */
class AudioController internal constructor(
    runtimeProvider: Lazy<AudioRuntime>,
    private val deleteHistoryAudio: (String) -> CompletableFuture<Unit> = { runtimeProvider.value.deleteHistoryAudio(it) },
) {
    constructor(context: Context) : this(lazy { AudioRuntime.get(context) })

    private val runtime by runtimeProvider
    fun start(activity: Activity) {
        check(!activity.isFinishing && !activity.isDestroyed &&
            ((activity as? LifecycleOwner)?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED)
                ?: activity.hasWindowFocus())) { "请从可见页面启动录音" }
        check(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) { "请先允许麦克风权限" }
        check(runtime.allowed()) { "录音未开启" }
        // Never runtime.lock on main: the worker holds it for seconds while it decrypts every file at first load.
        synchronized(runtime.control) {
            if (runtime.requested) return
            check(!runtime.recording) { "录音正在停止，请稍后重试" }
            runtime.requested = true
            runtime.generation++
            runtime.message = null
            runtime.processingProblem = null
            try {
                activity.startForegroundService(Intent(activity, AudioRecorderService::class.java)
                    .putExtra("generation", runtime.generation))
            } catch (e: Exception) { runtime.requested = false; runtime.report(R.string.recording_start_failed); throw e }
        }
    }
    fun stop(discardPending: Boolean = false) {
        synchronized(runtime.control) {
            if (!discardPending) runtime.app.prefs.audioCaptureWanted = false
            runtime.requested = false
            if (discardPending) runtime.generation++
            runtime.message = null
            runtime.processingProblem = null
        }
        runtime.context.stopService(Intent(runtime.context, AudioRecorderService::class.java))
        runtime.changed()
    }
    /** Bumps whenever recordings, voices or status change; pages re-read on it instead of polling. */
    val changes: StateFlow<Long> get() = runtime.changes
    internal fun state(): AudioState {
        val recording = runtime.recording
        return AudioState(recording, modelsReady(), recordingStatus(
            recording, runtime.silenced, runtime.playingOut,
            if (recording) runtime.processingProblem else runtime.message,
        ))
    }
    internal fun modelsReady() = runtime.models.current() != null
    internal fun storageUsage(): CompletableFuture<AudioStorageUsage> = runtime.read {
        synchronized(runtime.lock) { runtime.queries.storageUsage() }
    }
    fun listClips(): CompletableFuture<List<AudioClip>> = runtime.read {
        synchronized(runtime.lock) { runtime.queries.listClips() }
    }
    fun listConversations(): CompletableFuture<List<AudioConversation>> = runtime.read {
        synchronized(runtime.lock) { runtime.queries.listConversations() }
    }
    fun renderTranscript(recordId: String, fallbackBody: String): CompletableFuture<String> = runtime.read {
        synchronized(runtime.lock) { runtime.ledger.render(recordId, fallbackBody, runtime.macVoiceprint()) }
    }
    /** One read for a whole conversation instead of one per record; see [AudioLedger.renderAll]. */
    fun renderTranscripts(records: Map<String, String>): CompletableFuture<Map<String, String>> = runtime.read {
        synchronized(runtime.lock) { runtime.ledger.renderAll(records, runtime.macVoiceprint()) }
    }
    fun macVoiceKnown(): CompletableFuture<Boolean> = runtime.read {
        synchronized(runtime.lock) { runtime.queries.macVoiceKnown() }
    }
    fun listSpeakers(includeIgnored: Boolean = false): CompletableFuture<List<AudioSpeaker>> = runtime.read {
        synchronized(runtime.lock) { runtime.queries.listSpeakers(includeIgnored) }
    }
    fun markMe(id: String): CompletableFuture<Unit> {
        runtime.invalidatePolicy()
        return runtime.change { synchronized(runtime.lock) { runtime.ledger.markMe(id) }; runtime.drain() }
    }
    internal fun unmarkMe(id: String): CompletableFuture<VoiceMarkUndo> {
        runtime.invalidatePolicy()
        return runtime.change { synchronized(runtime.lock) { runtime.ledger.unmarkMe(id) } }
    }
    internal fun undoUnmarkMe(undo: VoiceMarkUndo): CompletableFuture<Unit> {
        runtime.invalidatePolicy()
        return runtime.change {
            synchronized(runtime.lock) { runtime.ledger.undoUnmarkMe(undo) }
            runtime.schedule()
        }
    }
    fun renameSpeaker(id: String, name: String?): CompletableFuture<Unit> = runtime.change {
        synchronized(runtime.lock) { runtime.ledger.rename(id, name) }
    }
    fun setIgnored(id: String, ignored: Boolean): CompletableFuture<Unit> {
        runtime.invalidatePolicy()
        return runtime.change { synchronized(runtime.lock) { runtime.ledger.ignore(id, ignored) } }
    }
    fun ignore(id: String): CompletableFuture<Unit> = setIgnored(id, true)
    internal fun modelPreparation() = runtime.modelPreparation
    fun downloadModels(): CompletableFuture<Unit> = runtime.downloadModels()
    fun supportsNpu() = QnnCatalog.supported()
    fun accelerationUsingFallback() = runtime.accelerationFallback
    fun accelerationReady() = runtime.qnnModels.current() != null
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
        return runtime.change { synchronized(runtime.lock) { runtime.store.clear() } }
    }
    /** Call before/with Vault deletion. Purges entire containing clip so backfill cannot recreate it. */
    fun deleteRecordAudio(recordId: String): CompletableFuture<Unit> = deleteHistoryAudio(recordId)
    internal val playingSpeaker get() = runtime.playback.speaker
    fun playSample(id: String): CompletableFuture<Unit> {
        val request = runtime.playback.toggle(id) ?: return CompletableFuture.completedFuture(Unit)
        return runtime.read {
            val pcm = synchronized(runtime.lock) {
                val span = requireNotNull(runtime.sample(id)) { "试听已过保留期" }
                val all = runtime.store.pcm(span.first)
                try { all.copyOfRange(span.second, span.third) } finally { all.fill(0f) }
            }
            try { runtime.play(request, pcm) } finally { pcm.fill(0f) }
        }.whenComplete { _, error -> if (error != null) runtime.playback.finish(request) }
    }
    fun stopPlayback() = runtime.playback.stop()
}

internal class AudioRuntime private constructor(val context: Context) {
    val app = context.applicationContext as TacitApp
    /** Guards recordings and voices; the worker may hold it for seconds (first load decrypts every file). */
    val lock = Any()
    /** Guards only requested/generation and the recording start handshake; held for microseconds, safe on main. */
    val control = Any()
    val store = EncryptedAudioStore(context)
    val ledger = AudioLedger(store)
    val queries = AudioQueries(store, ledger, ::retentionDays, ::sampledSpeakers, ::macVoiceprint)

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

    fun deleteHistoryAudio(recordId: String): CompletableFuture<Unit> {
        playback.stop()
        return change { synchronized(lock) { store.deleteRecord(recordId) } }
    }

    val models = SpeechModels(context)
    val qnnModels = QnnModels(context)
    @Volatile var accelerationFallback = false; private set
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "tacit-local-audio") }
    // Page reads only take [lock] briefly; they must not queue behind a long transcription drain on [worker].
    private val reader = Executors.newSingleThreadExecutor { r -> Thread(r, "tacit-audio-read") }
    private val modelWorker = Executors.newSingleThreadExecutor { r -> Thread(r, "tacit-model-download") }
    private val modelLock = Any()
    private var modelCancellation: ModelDownloadCancellation? = null
    @Volatile var modelPreparation = SpeechPreparationState()
        private set

    private fun beginModelPreparation(phase: SpeechPreparationPhase): ModelDownloadCancellation = synchronized(modelLock) {
        check(!modelPreparation.busy) { "模型正在准备，请等待完成或取消下载" }
        ModelDownloadCancellation().also {
            modelCancellation = it
            modelPreparation = SpeechPreparationState(phase, message = if (phase == SpeechPreparationPhase.IMPORTING) UiMessage(R.string.model_wait_recording) else UiMessage(R.string.model_connecting_download))
        }
    }
    fun cancelModelDownload() = synchronized(modelLock) {
        if (modelPreparation.canCancel && modelCancellation?.cancel() == true)
            modelPreparation = modelPreparation.copy(cancelling = true, message = UiMessage(R.string.model_cancelling))
    }
    private fun updateModelPreparation(phase: SpeechPreparationPhase, bytes: Long, message: UiMessage) = synchronized(modelLock) {
        modelPreparation = modelPreparation.copy(phase = phase, receivedBytes = bytes,
            message = if (modelPreparation.cancelling) UiMessage(R.string.model_cancelling) else message)
    }
    private fun modelFinished(error: Throwable?) = synchronized(modelLock) {
        modelPreparation = modelPreparation.finished(error)
        modelCancellation = null
    }
    fun downloadModels(): CompletableFuture<Unit> {
        val cancellation = beginModelPreparation(SpeechPreparationPhase.DOWNLOADING)
        return CompletableFuture.supplyAsync({
            val stage = models.download(cancellation) { bytes, path ->
                updateModelPreparation(SpeechPreparationPhase.DOWNLOADING, bytes, UiMessage(R.string.model_downloading_file, path))
            }
            try {
                cancellation.check()
                updateModelPreparation(SpeechPreparationPhase.VALIDATING, SpeechModelCatalog.totalBytes, UiMessage(R.string.model_wait_recording))
                // Only native load and pointer switch share the audio worker; network IO never blocks it.
                prepareModel {
                    cancellation.check()
                    updateModelPreparation(SpeechPreparationPhase.VALIDATING, SpeechModelCatalog.totalBytes, UiMessage(R.string.model_verified_loading))
                    replaceSpeechEngine(::closeEngine, ::schedule) { models.activate(stage, cancellation) }
                }.get()
            } catch (error: Throwable) {
                if (models.current() != stage) stage.deleteRecursively()
                throw error
            }
            Unit
        }, modelWorker).whenComplete { _, error -> modelFinished(error) }
    }
    fun downloadAcceleration(): CompletableFuture<Unit> {
        check(QnnCatalog.supported()) { "当前设备不支持本机加速" }
        val cancellation = beginModelPreparation(SpeechPreparationPhase.DOWNLOADING)
        synchronized(modelLock) { modelPreparation = modelPreparation.copy(totalBytes = QnnCatalog.archive.bytes) }
        return CompletableFuture.supplyAsync({
            check(models.current() != null) { "请先准备语音模型" }
            val stage = qnnModels.download(cancellation) { bytes, _ ->
                updateModelPreparation(SpeechPreparationPhase.DOWNLOADING, bytes, UiMessage(R.string.acceleration_downloading))
            }
            try {
                updateModelPreparation(SpeechPreparationPhase.VALIDATING, QnnCatalog.archive.bytes, UiMessage(R.string.model_wait_recording))
                prepareModel {
                    cancellation.check()
                    updateModelPreparation(SpeechPreparationPhase.VALIDATING, QnnCatalog.archive.bytes, UiMessage(R.string.acceleration_validating))
                    replaceSpeechEngine(::closeEngine, ::schedule) { qnnModels.activate(stage, cancellation) }
                }.get()
            } catch (error: Throwable) {
                if (qnnModels.current() != stage) stage.deleteRecursively()
                throw error
            }
            Unit
        }, modelWorker).whenComplete { _, error -> modelFinished(error) }
    }
    fun importModels(install: () -> java.io.File): CompletableFuture<Unit> {
        beginModelPreparation(SpeechPreparationPhase.IMPORTING)
        return prepareModel {
            updateModelPreparation(SpeechPreparationPhase.IMPORTING, 0, UiMessage(R.string.model_importing))
            replaceSpeechEngine(::closeEngine, ::schedule, install)
        }.whenComplete { _, error -> modelFinished(error) }
    }

    // Model operations have their own result in Speech Settings. Leave the recording message alone.
    private fun prepareModel(block: () -> Unit): CompletableFuture<Unit> = CompletableFuture.supplyAsync({
        block()
        reportProcessingProblem(generation, null)
        changed()
    }, worker)

    private val queued = AtomicBoolean(false)
    @Volatile var requested = false
    val changes = MutableStateFlow(0L)
    fun changed() = changes.update { it + 1 }
    @Volatile var recording = false
        set(value) { field = value; changed() }
    @Volatile var silenced = false
    @Volatile var playingOut = false
    @Volatile var generation = 0L
    private val policyRevisions = java.util.concurrent.atomic.AtomicLong()
    private val policyRevision get() = policyRevisions.get()
    @Volatile var message: Int? = null
    @Volatile var processingProblem: Int? = null
    private var engine: AcceleratedSpeechEngine? = null
    val playback = SamplePlayback()
    fun allowed() = app.prefs.enabled(AUDIO_SOURCE)
    fun invalidatePolicy() { policyRevisions.incrementAndGet() }
    fun report(text: Int) { message = text; changed() }
    fun <T> submit(block: () -> T): CompletableFuture<T> = CompletableFuture.supplyAsync(block, worker)
    /** Read-only queries that hold [lock] themselves; they run beside the processing [worker]. */
    fun <T> read(block: () -> T): CompletableFuture<T> = CompletableFuture.supplyAsync(block, reader)
    /** For work that changes recordings or voices: signals pages even when the work fails halfway. */
    fun <T> change(block: () -> T): CompletableFuture<T> = submit { try { block() } finally { changed() } }
    fun closeEngine() { engine?.close(); engine = null; accelerationFallback = false }
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
        }.whenComplete { _, error ->
            if (error != null) reportProcessingProblem(token, R.string.recording_save_failed)
        }
    }

    private fun reportProcessingProblem(token: Long, problem: Int?) {
        synchronized(control) {
            if (generation != token || !requested || processingProblem == problem) return
            processingProblem = problem
        }
        changed()
    }

    fun schedule() {
        if (!queued.compareAndSet(false, true)) return
        submit {
            val policyAtStart = policyRevision
            val token = generation
            var completed = false
            try {
                drain()
                completed = true
            } catch (error: Throwable) {
                reportProcessingProblem(token, R.string.audio_processing_failed)
                throw error
            } finally {
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
        val dir = models.current() ?: return
        val speech = engine ?: AcceleratedSpeechEngine(LocalSpeechEngine(dir), context, qnnModels.current()) { status ->
            accelerationFallback = status == QNN_UNAVAILABLE || status == QNN_INTERRUPTED
        }.also { engine = it }
        AudioProcessor(store, lock, speech, voiceprint).drain({ allowed() && token == generation && policy == policyRevision }) { p ->
            app.vault.ingest(Draft(source = AUDIO_SOURCE, title = STORED_CONVERSATION_TITLE, body = p.body,
                start = p.start, end = p.end,
                sourceRef = "audio:${p.clipId}", method = "asr"), offset = p.offset)
        }
        reportProcessingProblem(token, null)
        changed()
    }
    /** Voices that still have audio to play, in one pass instead of searching every clip once per voice. */
    fun sampledSpeakers(): Set<String> {
        val found = HashSet<String>()
        for (clip in store.clips()) {
            val voices = clip.getJSONArray("utterances").objects().map { it.getString("speaker") }
            if (voices.any { it !in found } && store.exists(clip.getString("id"))) found += voices
        }
        return found
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
    fun play(request: SamplePlayback.Request, pcm: FloatArray) {
        val shorts = ShortArray(pcm.size) { (pcm[it].coerceIn(-1f, 1f) * 32767).toInt().toShort() }
        val track = try {
            AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(shorts.size * 2).build().also { track ->
                    try { check(track.write(shorts, 0, shorts.size) == shorts.size) }
                    catch (error: Exception) { track.release(); throw error }
                }
        } finally { shorts.fill(0) }
        playback.play(request, start = {
            track.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(track: AudioTrack) = playback.finish(request)
                override fun onPeriodicNotification(track: AudioTrack) = Unit
            }, android.os.Handler(context.mainLooper))
            check(track.setNotificationMarkerPosition(pcm.size) == AudioTrack.SUCCESS)
            track.play()
        }, close = {
            runCatching { track.stop() }
            track.release()
        })
    }
    companion object {
        @Volatile private var instance: AudioRuntime? = null
        fun get(context: Context): AudioRuntime = instance ?: synchronized(this) {
            instance ?: AudioRuntime(context.applicationContext).also { instance = it }
        }
    }
}

internal fun recordingStatus(recording: Boolean, silenced: Boolean, playingOut: Boolean, message: Int?): Int? = when {
    recording && silenced -> R.string.recording_mic_busy
    recording && playingOut -> R.string.recording_speaker_playing
    else -> message
}
