package top.jinso.tacit.audio

import org.json.JSONArray
import org.json.JSONObject
import top.jinso.tacit.sync.MacVoiceprint
import top.jinso.tacit.core.Secrets
import java.util.UUID

internal fun transcriptSpeakerLabel(speaker: JSONObject?, number: () -> Int): String {
    if (speaker?.optBoolean("me") == true) return "我"
    return speaker?.optString("name")?.takeIf(String::isNotEmpty) ?: "对方 ${number()}"
}

/** Encrypted index operations. Caller holds AudioRuntime.lock; no content goes through Preferences. */
internal class AudioLedger(private val store: EncryptedAudioStore) {
    private val conversations: JSONArray get() = store.index.optJSONArray("conversations")
        ?: JSONArray().also { store.index.put("conversations", it) }

    // Keep legacy meeting intervals and imported recordings separate when rebuilding an old index.
    private fun contextKey(clip: JSONObject) = clip.optString("origin", "microphone") + ":" + clip.optString("meeting")
    private fun utterances(clip: JSONObject) = clip.getJSONArray("utterances").objects()
    private fun start(clip: JSONObject) = clip.getLong("start") +
        (utterances(clip).minOfOrNull { it.getInt("start") } ?: 0) * 1000L / SAMPLE_RATE
    private fun end(clip: JSONObject) = clip.getLong("start") +
        (utterances(clip).maxOfOrNull { it.getInt("start") + it.getInt("length") } ?: 0) * 1000L / SAMPLE_RATE

    /**
     * Migrates legacy indexes conservatively; legacy VAD counts never qualify as conversation counts.
     * Persists the head and the clips and voices it changed, plus [clips] and [speakers] the caller changed.
     * Writes nothing when nothing changed.
     */
    fun prepare(clips: Collection<JSONObject> = emptyList(), speakers: Collection<JSONObject> = emptyList()): Boolean {
        var changed = false
        val changedClips = clips.toMutableSet()
        val changedSpeakers = speakers.toMutableSet()
        val observed = mutableMapOf<String, MutableSet<String>>()
        val published = store.transcripts().mapTo(mutableSetOf()) { it.getString("recordId") }
        for (clip in store.clips().sortedBy { it.getLong("start") }) {
            val rows = utterances(clip)
            if (!clip.getBoolean("analyzed") || rows.isEmpty()) continue
            if (clip.optString("conversation").isEmpty()) {
                attach(clip)
                changedClips += clip
                changed = true
            }
            val conversation = clip.getString("conversation")
            for (row in rows) {
                observed.getOrPut(row.getString("speaker")) { mutableSetOf() }.add(conversation)
                val record = row.optString("record")
                if (record.isNotEmpty() && published.add(record)) {
                    persistTranscript(clip, record)
                    changed = true
                }
            }
        }
        for (speaker in store.speakers()) {
            val existing = speaker.optJSONArray("conversations")
            val ids = existing?.let { a -> (0 until a.length()).mapTo(mutableSetOf()) { a.getString(it) } }
                ?: mutableSetOf()
            val additions = observed[speaker.getString("id")].orEmpty() - ids
            if (existing == null || additions.isNotEmpty()) {
                speaker.put("conversations", JSONArray((ids + additions).toList()))
                changedSpeakers += speaker
                changed = true
            }
        }
        if (changed || changedClips.isNotEmpty() || changedSpeakers.isNotEmpty()) store.commit(changedClips, changedSpeakers)
        return changed
    }

    fun attach(clip: JSONObject): JSONObject {
        val existing = clip.optString("conversation")
        if (existing.isNotEmpty()) return conversations.objects().first { it.getString("id") == existing }
        // Each selected recording has its own timeline; overlapping microphone/import clips cannot split it.
        val timeline = store.clips().filter { it.optString("origin", "microphone") == clip.optString("origin", "microphone") }
        val previous = timeline.filter { it !== clip && it.getBoolean("analyzed") &&
            it.getLong("start") <= clip.getLong("start") }.maxByOrNull { it.getLong("start") }
        // Empty clips do not extend speech time, but a context transition still splits the conversation.
        val last = previous?.let { p ->
            timeline.filter { it !== clip && it.optString("conversation").isNotEmpty() &&
                it.getLong("start") <= p.getLong("start") }.maxByOrNull { it.getLong("start") }
        }
        val same = last != null && contextKey(previous!!) == contextKey(clip) &&
            AudioPolicy.adjacent(end(last), start(clip), contextKey(last), contextKey(clip)) &&
            timeline.none { it.getLong("start") > last.getLong("start") &&
                it.getLong("start") < clip.getLong("start") && contextKey(it) != contextKey(clip) }
        val conversation = if (same) conversations.objects().first { it.getString("id") == last!!.getString("conversation") }
        else JSONObject().put("id", UUID.randomUUID().toString()).put("labels", JSONObject())
            .also { conversations.put(it) }
        clip.put("conversation", conversation.getString("id"))
        utterances(clip).forEach { participantLabel(conversation, it.getString("speaker")) }
        return conversation
    }

    private fun participantLabel(conversation: JSONObject, speaker: String): Int {
        val labels = conversation.getJSONObject("labels")
        if (!labels.has(speaker)) labels.put(speaker, labels.length() + 1)
        return labels.getInt(speaker)
    }
    fun label(clip: JSONObject, speaker: String): Int = participantLabel(
        conversations.objects().first { it.getString("id") == clip.getString("conversation") }, speaker)

    fun assign(vector: FloatArray, seconds: Double): JSONObject {
        val scored = store.speakers().map { it to AudioPolicy.cosine(vector, it.vectorAt("vector")) }
        val (best, score) = scored.maxByOrNull { it.second } ?: (null to -1.0)
        if (best != null && score >= .6) {
            val old = best.vectorAt("vector"); val weight = best.getDouble("seconds")
            if (!best.optBoolean("me") && !best.optBoolean("ignored") && best.optString("name").isEmpty()) {
                best.putVector("vector", AudioPolicy.unit(FloatArray(vector.size) {
                    ((old[it] * weight + vector[it] * seconds) / (weight + seconds)).toFloat()
                }))
            }
            best.put("seconds", weight + seconds).put("segments", best.getInt("segments") + 1)
            return best
        }
        return JSONObject().put("id", UUID.randomUUID().toString()).putVector("vector", vector)
            .put("order", System.currentTimeMillis()).put("seconds", seconds).put("segments", 1).put("conversations", JSONArray())
            .also { store.index.getJSONArray("speakers").put(it) }
    }

    /** The voice that authorizes transcription: the Mac voiceprint when paired, otherwise the voice marked "me". */
    fun meVoice(mac: MacVoiceprint? = null): FloatArray? =
        mac?.vector ?: store.speakers().firstOrNull { it.optBoolean("me") && !it.optBoolean("ignored") }?.vectorAt("vector")

    /**
     * [presence] caches, per conversation, whether "me" speaks in retained audio. Pass one map for a whole
     * drain: any change that could flip the answer (me, deletion, pause) also ends that drain.
     */
    fun eligible(clip: JSONObject, allowed: Boolean, mac: MacVoiceprint? = null,
        voice: FloatArray? = meVoice(mac), presence: MutableMap<String, Boolean> = mutableMapOf()): Boolean {
        val threshold = mac?.threshold ?: .6
        val conversation = clip.optString("conversation")
        val present = voice != null && conversation.isNotEmpty() && presence.getOrPut(conversation) {
            store.clips().any { other ->
                other.optString("conversation") == conversation && store.exists(other.getString("id")) &&
                    utterances(other).any { u -> u.vectorOrNull("vector")?.let {
                        AudioPolicy.mayTranscribe(voice, it, allowed, threshold)
                    } == true }
            }
        }
        return store.exists(clip.getString("id")) && AudioPolicy.conversationAllowed(
            voice != null, present, allowed)
    }

    fun rename(id: String, name: String?) {
        val clean = name?.trim()?.takeIf(String::isNotEmpty)
        require(clean == null || (clean.length <= 80 && clean.none(Char::isISOControl))) { "姓名需在 80 字以内" }
        store.saveSpeakers(listOf(speaker(id).put("name", clean?.let { Secrets.redact(it).text })))
    }
    fun markMe(id: String) {
        val target = speaker(id)
        store.speakers().forEach { it.put("me", it === target) }
        target.put("ignored", false); store.saveSpeakers(store.speakers())
    }
    fun unmarkMe(id: String) { store.saveSpeakers(listOf(speaker(id).put("me", false))) }
    fun ignore(id: String, ignored: Boolean) {
        store.saveSpeakers(listOf(speaker(id).put("ignored", ignored).apply { if (ignored) put("me", false) }))
    }
    private fun findSpeaker(id: String) = store.speakers().firstOrNull { it.getString("id") == id }
    private fun speaker(id: String) = requireNotNull(findSpeaker(id)) { "说话人已不存在" }

    fun transcriptLabel(clip: JSONObject, speakerId: String): String =
        transcriptSpeakerLabel(findSpeaker(speakerId)) { label(clip, speakerId) }

    fun persistTranscript(clip: JSONObject, record: String) {
        if (store.transcripts().any { it.getString("recordId") == record }) return
        val rows = utterances(clip).map { u -> JSONObject().put("start", u.getInt("start"))
            .put("length", u.getInt("length")).put("speaker", u.getString("speaker"))
            .put("label", label(clip, u.getString("speaker"))).apply { if (u.has("text")) put("text", u.getString("text")) } }
        val transcripts = store.index.optJSONArray("transcripts")
            ?: JSONArray().also { store.index.put("transcripts", it) }
        transcripts.put(JSONObject().put("recordId", record)
            .put("clipId", clip.getString("id")).put("conversationId", clip.getString("conversation"))
            .put("start", start(clip)).put("end", end(clip))
            .put("utterances", JSONArray(rows)))
    }

    fun render(record: String, fallback: String): String {
        val row = store.transcripts().firstOrNull { it.getString("recordId") == record } ?: return fallback
        val lines = row.getJSONArray("utterances").objects().mapNotNull { u ->
            val text = u.optString("text"); if (text.isBlank()) return@mapNotNull null
            val name = transcriptSpeakerLabel(findSpeaker(u.getString("speaker"))) { u.getInt("label") }
            "$name：$text"
        }
        return lines.takeIf { it.isNotEmpty() }?.joinToString("\n") ?: fallback
    }

    fun listConversations(): List<AudioConversation> {
        val rows = store.transcripts().map { r -> AudioConversation(r.getString("conversationId"),
            r.getLong("start"), r.getLong("end"), listOf(r.getString("clipId")), listOf(r.getString("recordId"))) } +
            store.clips().filter { it.optString("conversation").isNotEmpty() }.map { clip ->
                AudioConversation(clip.getString("conversation"), start(clip), end(clip),
                    listOf(clip.getString("id")), emptyList())
            }
        return rows.groupBy { it.id }.map { (id, parts) ->
            AudioConversation(id, parts.minOf { it.start }, parts.maxOf { it.end },
                parts.flatMap { it.clipIds }.distinct(), parts.flatMap { it.recordIds }.distinct())
        }.sortedByDescending { it.start }
    }
}
