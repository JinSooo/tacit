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
            ledger.prepare()
            store.clips().filter { microphoneClip(it) && store.exists(it.getString("id")) }.sortedBy { it.getLong("start") }
        }
        for (clip in clips) {
            if (!allowed()) return
            if (clip.getBoolean("analyzed")) {
                // Clips analyzed before silent audio was dropped at analysis time.
                if (clip.getJSONArray("utterances").length() == 0) synchronized(lock) {
                    if (store.exists(clip.getString("id"))) store.discard(clip.getString("id"))
                }
                continue
            }
            val pcm = synchronized(lock) {
                val id = clip.getString("id")
                if (store.exists(id)) store.pcm(id) else null
            } ?: continue
            val spans = try { speech.segments(pcm) } finally { pcm.fill(0f) }
            try {
                synchronized(lock) {
                    if (!allowed() || !store.exists(clip.getString("id"))) return
                    // Only conversations with a voice are worth keeping; silence never waits out the retention period.
                    if (spans.isEmpty()) { store.discard(clip.getString("id")); return@synchronized }
                    val utterances = JSONArray()
                    val voices = mutableSetOf<JSONObject>()
                    for (span in spans) {
                        require(span.start >= 0 && span.start + span.samples.size <= clip.getInt("samples"))
                        val speaker = ledger.assign(span.vector, span.samples.size.toDouble() / SAMPLE_RATE)
                        voices += speaker
                        utterances.put(JSONObject().put("start", span.start).put("length", span.samples.size)
                            .put("speaker", speaker.getString("id")).putVector("vector", span.vector)
                            .put("done", false))
                    }
                    clip.put("utterances", utterances).put("analyzed", true)
                    ledger.prepare(listOf(clip), voices)
                }
            } finally { spans.forEach { it.samples.fill(0f) } }
        }
        // Without a "me" voice nothing is eligible; skip the pass instead of checking every clip.
        val voice = synchronized(lock) { ledger.meVoice(macVoiceprint) } ?: return
        val presence = mutableMapOf<String, Boolean>()
        fun eligible(clip: JSONObject) = ledger.eligible(clip, allowed(), macVoiceprint, voice, presence)
        for (clip in clips) {
            if (!allowed()) return
            val utterances = clip.getJSONArray("utterances").objects()
            if (utterances.all { it.optBoolean("done") }) continue
            if (!synchronized(lock) { eligible(clip) }) continue
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
                    if (!eligible(clip)) return
                    utterances.zip(texts).forEach { (u, text) -> u.put("text", text) }
                    clip.put("textPrepared", true); store.saveClip(clip)
                }
            }
            synchronized(lock) {
                if (!eligible(clip)) return
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
                store.save(clip)
            }
        }
    }
}
