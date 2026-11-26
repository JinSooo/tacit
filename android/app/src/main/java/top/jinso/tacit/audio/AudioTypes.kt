package top.jinso.tacit.audio

import kotlin.math.sqrt

import top.jinso.tacit.sources.Sources

const val AUDIO_SOURCE = Sources.AUDIO
internal const val SAMPLE_RATE = 16000

internal data class AudioState(val recording: Boolean, val modelsReady: Boolean, val message: Int?)
data class AudioClip(val id: String, val start: Long, val durationMs: Long, val analyzed: Boolean,
    val conversationId: String? = null)
data class AudioSpeaker(val id: String, val isMe: Boolean, val ignored: Boolean,
    val segments: Int, val seconds: Double, val sampleAvailable: Boolean,
    val name: String? = null, val conversations: Int = 0, val lastSeen: Long? = null)
data class AudioConversation(val id: String, val start: Long, val end: Long,
    val clipIds: List<String>, val recordIds: List<String>)

/** Pure policy, independently testable without microphone/native libraries. */
internal object AudioPolicy {
    /** Output types that keep media out of the microphone; anything else counts as the phone's own speaker. */
    private val privateOutputs = setOf(
        android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET, android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        android.media.AudioDeviceInfo.TYPE_USB_HEADSET, 26 /* TYPE_BLE_HEADSET */, 27 /* TYPE_BLE_SPEAKER */,
    )
    /**
     * AudioSet indices from class_labels_indices.csv. Calibrated on this phone's retained audio (2026-11-21): real
     * talking scored at most .29 for music-like classes, the voices that turned out to be songs mostly .4–.87.
     * Singing also scores high on Speech, so speech is not used to veto; talking over loud music is dropped too.
     */
    fun music(probabilities: Map<Int, Float>): Boolean =
        listOf(MUSIC, SINGING, SONG, VOCAL_MUSIC, POP_MUSIC).maxOf { probabilities[it] ?: 0f } >= .4f
    private const val SINGING = 27
    private const val MUSIC = 137
    private const val POP_MUSIC = 216
    private const val VOCAL_MUSIC = 254
    private const val SONG = 266
    /** The phone playing video or music aloud would be recorded as other people's voices, so capture pauses. */
    fun speakerPlayback(musicActive: Boolean, outputTypes: Collection<Int>) =
        musicActive && outputTypes.none { it in privateOutputs }
    fun candidate(conversations: Int, seconds: Double) = (conversations >= 2 && seconds >= 15) || seconds >= 45
    fun adjacent(previousEnd: Long, nextStart: Long, previousContext: String, context: String) =
        previousContext == context && nextStart >= previousEnd && nextStart - previousEnd <= 600_000L
    /**
     * Speech counted as "me" across a conversation must add up to [ME_PRESENT_SECONDS]. On 2026-11-23 a game the user
     * never heard put 11.7 s of short lines on voices matching the Mac voiceprint (center .605, as close as the
     * user's real talks at .55–.59); the user's real conversations had 53–87 s.
     */
    fun mePresent(meSeconds: Double) = meSeconds >= ME_PRESENT_SECONDS
    const val ME_PRESENT_SECONDS = 20.0
    fun conversationAllowed(meMarked: Boolean, mePresentInRetainedAudio: Boolean,
        allowed: Boolean) = allowed && meMarked && mePresentInRetainedAudio
    fun unit(v: FloatArray): FloatArray {
        require(v.isNotEmpty() && v.all { it.isFinite() }) { "Invalid speaker embedding" }
        val norm = sqrt(v.sumOf { it.toDouble() * it })
        require(norm > 1e-8) { "Empty speaker embedding" }
        return FloatArray(v.size) { (v[it] / norm).toFloat() }
    }
    fun cosine(a: FloatArray, b: FloatArray): Double =
        if (a.size != b.size || a.isEmpty()) -1.0 else a.indices.sumOf { a[it].toDouble() * b[it] }
    fun expired(start: Long, now: Long, days: Int) = days > 0 && start < now - days * 86_400_000L
}
