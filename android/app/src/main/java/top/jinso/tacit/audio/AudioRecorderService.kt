package top.jinso.tacit.audio

import android.content.res.Configuration
import android.content.Context
import top.jinso.tacit.i18n.AppLocale
import top.jinso.tacit.R
import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder

/** Never auto-started at boot or restarted by the OS. Only AudioController.start(visibleActivity). */
class AudioRecorderService : Service() {
    override fun attachBaseContext(newBase: Context) = super.attachBaseContext(AppLocale.wrapLegacy(newBase))

    private lateinit var runtime: AudioRuntime
    @Volatile private var running = false
    @Volatile private var recorder: AudioRecord? = null
    private var thread: Thread? = null
    override fun onCreate() { super.onCreate(); runtime = AudioRuntime.get(this) }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val token = intent?.getLongExtra("generation", -1) ?: -1
        if (intent?.action == "stop") { AudioController(this).stop(); stopSelf(); return START_NOT_STICKY }
        if (!runtime.requested || token != runtime.generation || !runtime.allowed() ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            stopSelf(); return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        try {
            val notification = recordingNotification()
            if (Build.VERSION.SDK_INT >= 30) startForeground(701, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(701, notification)
            running = true
            thread = Thread({ capture(token) }, "tacit-microphone").also { it.start() }
        } catch (e: Exception) {
            runtime.requested = false; runtime.report(R.string.recording_start_failed); stopSelf()
        }
        return START_NOT_STICKY
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (running) getSystemService(NotificationManager::class.java).notify(701, recordingNotification())
    }

    private fun recordingNotification(): Notification {
        val strings = AppLocale.strings(this)
        val manager = getSystemService(NotificationManager::class.java)
        val channel = "tacit.audio"
        manager.createNotificationChannel(NotificationChannel(channel, strings.text(R.string.recording), NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 701, Intent(this, AudioRecorderService::class.java).setAction("stop"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, channel)
            .setContentTitle(strings.text(R.string.recording_notification_title))
            .setContentText(strings.text(R.string.recording_notification_body))
            .setSmallIcon(R.drawable.ic_stat_tacit)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, strings.text(R.string.stop), stop).build()).build()
    }

    private fun capture(token: Long) {
        var input: AudioRecord? = null
        var callback: AudioManager.AudioRecordingCallback? = null
        val silence = CaptureSilenceGate()
        val segment = ShortArray(SAMPLE_RATE * 30)
        val block = ShortArray(1600)
        var used = 0; var start = System.currentTimeMillis()
        var needsTimestamp = true
        try {
            val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0)
            if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) { runtime.report(R.string.recording_mic_revoked);return }
            val builder = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(minimum * 2, SAMPLE_RATE))
            if (Build.VERSION.SDK_INT >= 30) builder.setPrivacySensitive(false)
            input = builder.build()
            check(input.state == AudioRecord.STATE_INITIALIZED)
            // Prefer built-in microphone; avoid switching a Bluetooth headset into call mode.
            val audioManager = getSystemService(android.media.AudioManager::class.java)
            audioManager.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
                .firstOrNull { it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC }?.let { input.setPreferredDevice(it) }
            if (Build.VERSION.SDK_INT >= 29) {
                val session = input.audioSessionId
                callback = object : AudioManager.AudioRecordingCallback() {
                    override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                        configs.firstOrNull { it.clientAudioSessionId == session }?.let { config ->
                            silence.update(config.isClientSilenced)
                        }
                    }
                }
                // Official sharing contract: register BEFORE start; keep this recorder while silenced.
                input.registerAudioRecordingCallback(mainExecutor, callback)
            }
            recorder = input; input.startRecording()
            check(input.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            synchronized(runtime.control) {
                // A stop/pause may race the native start. Only a still-wanted, successful start persists intent.
                if (!running || !runtime.requested || token != runtime.generation || !runtime.allowed()) return
                runtime.app.prefs.audioCaptureWanted = true
                runtime.message = null
                runtime.recording = true
            }
            runtime.schedule()
            var lastRevision = silence.revision
            // The registered callback reports silencing as it happens. Polling the configuration is a
            // cross-process call, so it and the preference-backed permission check run about once a second.
            var reads = 0
            var allowed = true
            while (running && runtime.requested && token == runtime.generation && allowed) {
                val poll = reads++ % POLL_EVERY_READS == 0
                if (poll) {
                    allowed = runtime.allowed()
                    if (Build.VERSION.SDK_INT >= 29) input.activeRecordingConfiguration?.let { silence.update(it.isClientSilenced) }
                    // Listing outputs is a heavy audioserver call; only pay for it while something is playing.
                    val music = audioManager.isMusicActive
                    val playing = music && AudioPolicy.speakerPlayback(true,
                        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type })
                    if (playing != runtime.playingOut) {
                        runtime.playingOut = playing
                        runtime.changed()
                    }
                }
                val n = input.read(block, 0, minOf(block.size, segment.size - used), AudioRecord.READ_BLOCKING)
                if (n < 0) { if (!running) break else error("AudioRecord read failed") }
                if (silence.drop(lastRevision)) {
                    block.fill(0); segment.fill(0); used = 0; needsTimestamp = true
                    if (runtime.silenced != silence.silenced) {
                        runtime.silenced = silence.silenced
                        runtime.changed()
                    }
                    lastRevision = silence.revision
                    continue
                }
                if (n == 0) continue
                if (runtime.playingOut) {
                    // Drop what the speaker played; the next kept audio starts a fresh segment.
                    block.fill(0); segment.fill(0); used = 0; needsTimestamp = true
                    continue
                }
                if (needsTimestamp) {
                    start = System.currentTimeMillis() - n * 1000L / SAMPLE_RATE
                    needsTimestamp = false
                }
                block.copyInto(segment, used, 0, n); used += n; block.fill(0)
                if (used == segment.size) {
                    runtime.captured(segment, start, token)
                    start += segment.size * 1000L / SAMPLE_RATE
                    segment.fill(0); used = 0
                }
            }
            // Explicit stop retains the last segment; pause/revocation discards it.
        } catch (e: Exception) {
            if (running && runtime.requested) {
                runtime.report(if (runtime.recording) R.string.recording_interrupted
                    else R.string.recording_start_failed)
            }
        } finally {
            if (!silence.silenced && used >= SAMPLE_RATE / 2) {
                val tail=segment.copyOf(used)
                try { runtime.captured(tail,start,token,final=true) } catch (_: Exception) { runtime.report(R.string.recording_tail_failed) } finally { tail.fill(0) }
            }
            synchronized(runtime.control) {
                running = false
                runtime.silenced = false
                runtime.playingOut = false
                runtime.processingProblem = null
                if (token == runtime.generation) runtime.requested = false
                runtime.recording = false
            }
            segment.fill(0); block.fill(0)
            if (Build.VERSION.SDK_INT >= 29) callback?.let { cb -> runCatching { input?.unregisterAudioRecordingCallback(cb) } }
            runCatching { input?.stop() }; input?.release(); recorder = null
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        }
    }
    private companion object { const val POLL_EVERY_READS = 10 }
    override fun onDestroy() {
        running = false
        runCatching { recorder?.stop() }
        super.onDestroy()
    }
}
