package top.jinso.tacit.audio

import org.json.JSONArray
import org.json.JSONObject
import top.jinso.tacit.core.Secrets
import top.jinso.tacit.sync.MacVoiceprint

internal interface SpeechEngine {
    fun segments(pcm: FloatArray): List<VoiceSegment>
    fun transcribe(samples: FloatArray): String
}
internal data class AudioPublication(val clipId: String,
    val body: String, val start: Long, val end: Long)

internal fun microphoneClip(clip: JSONObject): Boolean =
    clip.optString("origin", "microphone") == "microphone"

/** Two passes: find voices in ALL retained clips before authorizing ASR for any conversation. */
internal class AudioProcessor(private val store: EncryptedAudioStore, private val lock: Any,
    private val speech: SpeechEngine, private val macVoiceprint: MacVoiceprint? = null) {
    /** publish must return the existing record ID on a duplicate clipId; null means rejected/tombstoned. */
    fun drain(allowed: () -> Boolean, publish: (AudioPublication) -> String?) {
        val ledger = AudioLedger(store)
        val clips = synchronized(lock) {
            if (ledger.prepare()) store.save()
            store.clips().filter { microphoneClip(it) && store.exists(it.getString("id")) }.sortedBy { it.getLong("start") }
        }
        for (clip in clips) {
            if (!allowed()) return
            if (clip.getBoolean("analyzed")) continue
            val pcm = synchronized(lock) {
                val id = clip.getString("id")
                if (store.exists(id)) store.pcm(id) else null
            } ?: continue
            val spans = try { speech.segments(pcm) } finally { pcm.fill(0f) }
            try {
                synchronized(lock) {
                    if (!allowed() || !store.exists(clip.getString("id"))) return
                    val utterances = JSONArray()
                    for (span in spans) {
                        require(span.start >= 0 && span.start + span.samples.size <= clip.getInt("samples"))
                        val speaker = ledger.assign(span.vector, span.samples.size.toDouble() / SAMPLE_RATE)
                        utterances.put(JSONObject().put("start", span.start).put("length", span.samples.size)
                            .put("speaker", speaker.getString("id")).put("vector", JSONArray(span.vector.toList()))
                            .put("done", false))
                    }
                    clip.put("utterances", utterances).put("analyzed", true)
                    ledger.prepare(); store.save()
                }
            } finally { spans.forEach { it.samples.fill(0f) } }
        }
        for (clip in clips) {
            if (!allowed()) return
            val utterances = clip.getJSONArray("utterances").objects()
            if (utterances.all { it.optBoolean("done") }) continue
            if (!synchronized(lock) { ledger.eligible(clip, allowed(), macVoiceprint) }) continue
            if (!clip.optBoolean("textPrepared")) {
                val pcm = synchronized(lock) {
                    val id = clip.getString("id")
                    if (store.exists(id)) store.pcm(id) else null
                } ?: continue
                val texts = try {
                    utterances.map { u ->
                        if (!allowed()) return
                        val samples = pcm.copyOfRange(u.getInt("start"), u.getInt("start") + u.getInt("length"))
                        try { Secrets.redact(speech.transcribe(samples)).text } finally { samples.fill(0f) }
                    }
                } finally { pcm.fill(0f) }
                synchronized(lock) {
                    if (!ledger.eligible(clip, allowed(), macVoiceprint)) return
                    utterances.zip(texts).forEach { (u, text) -> u.put("text", text) }
                    clip.put("textPrepared", true); store.save()
                }
            }
            synchronized(lock) {
                if (!ledger.eligible(clip, allowed(), macVoiceprint)) return
                val body = utterances.filter { it.optString("text").isNotBlank() }.joinToString("\n") {
                    "对方 ${ledger.label(clip, it.getString("speaker"))}：${it.getString("text")}"
                }
                val record = if (body.isNotEmpty()) publish(AudioPublication(clip.getString("id"),
                    body, clip.getLong("start"),
                    clip.getLong("start") + clip.getInt("samples") * 1000L / SAMPLE_RATE)) else null
                if (record != null) ledger.persistTranscript(clip, record)
                utterances.forEach { u ->
                    if (record != null) u.put("record", record)
                    u.remove("text")
                    u.put("done", true)
                }
                store.save()
            }
        }
    }
}
