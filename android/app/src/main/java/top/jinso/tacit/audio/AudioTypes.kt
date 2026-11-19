package top.jinso.tacit.audio

import kotlin.math.sqrt

import top.jinso.tacit.sources.Sources

const val AUDIO_SOURCE = Sources.AUDIO
internal const val SAMPLE_RATE = 16000

data class AudioState(val recording: Boolean, val modelsReady: Boolean, val message: String)
data class AudioClip(val id: String, val start: Long, val durationMs: Long, val analyzed: Boolean,
    val conversationId: String? = null)
data class AudioSpeaker(val id: String, val isMe: Boolean, val ignored: Boolean,
    val segments: Int, val seconds: Double, val sampleAvailable: Boolean,
    val name: String? = null, val conversations: Int = 0)
data class AudioConversation(val id: String, val start: Long, val end: Long,
    val clipIds: List<String>, val recordIds: List<String>)

/** Pure policy, independently testable without microphone/native libraries. */
internal object AudioPolicy {
    fun candidate(conversations: Int, seconds: Double) = (conversations >= 2 && seconds >= 15) || seconds >= 45
    fun adjacent(previousEnd: Long, nextStart: Long, previousContext: String, context: String) =
        previousContext == context && nextStart >= previousEnd && nextStart - previousEnd <= 600_000L
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
    fun mayTranscribe(me: FloatArray?, utterance: FloatArray, allowed: Boolean) =
        allowed && me != null && cosine(me, utterance) >= .6
    fun expired(start: Long, now: Long, days: Int) = start < now - days.coerceIn(1, 90) * 86_400_000L
}
