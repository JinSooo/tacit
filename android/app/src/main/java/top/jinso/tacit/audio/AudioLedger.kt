package top.jinso.tacit.audio

import org.json.JSONArray
import org.json.JSONObject
import top.jinso.tacit.core.Secrets
import java.util.UUID

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

    /** Migrates legacy indexes conservatively; legacy VAD counts never qualify as conversation counts. */
    fun prepare(): Boolean {
        var changed = false
        val observed = mutableMapOf<String, MutableSet<String>>()
        val published = store.transcripts().mapTo(mutableSetOf()) { it.getString("recordId") }
        for (clip in store.clips().sortedBy { it.getLong("start") }) {
            val rows = utterances(clip)
            if (!clip.getBoolean("analyzed") || rows.isEmpty()) continue
            if (clip.optString("conversation").isEmpty()) {
                attach(clip)
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
                changed = true
            }
        }
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
        val best = store.speakers().maxByOrNull { AudioPolicy.cosine(vector, it.getJSONArray("vector").vector()) }
        if (best != null && AudioPolicy.cosine(vector, best.getJSONArray("vector").vector()) >= .6) {
            val old = best.getJSONArray("vector").vector(); val weight = best.getDouble("seconds")
            if (!best.optBoolean("me") && !best.optBoolean("ignored") && best.optString("name").isEmpty()) {
                best.put("vector", JSONArray(AudioPolicy.unit(FloatArray(vector.size) {
                    ((old[it] * weight + vector[it] * seconds) / (weight + seconds)).toFloat()
                }).toList()))
            }
            best.put("seconds", weight + seconds).put("segments", best.getInt("segments") + 1)
            return best
        }
        return JSONObject().put("id", UUID.randomUUID().toString()).put("vector", JSONArray(vector.toList()))
            .put("seconds", seconds).put("segments", 1).put("conversations", JSONArray())
            .also { store.index.getJSONArray("speakers").put(it) }
    }

    fun eligible(clip: JSONObject, allowed: Boolean): Boolean {
        val me = store.speakers().firstOrNull { it.optBoolean("me") && !it.optBoolean("ignored") }
        val conversation = clip.optString("conversation")
        val presence = me != null && conversation.isNotEmpty() && store.clips().any { other ->
            other.optString("conversation") == conversation && store.exists(other.getString("id")) &&
                utterances(other).any { u -> u.optJSONArray("vector")?.let {
                    AudioPolicy.mayTranscribe(me.getJSONArray("vector").vector(), it.vector(), true)
                } == true }
        }
        return store.exists(clip.getString("id")) && AudioPolicy.conversationAllowed(
            me != null, presence, allowed)
    }

    fun rename(id: String, name: String?) {
        val clean = name?.trim()?.takeIf(String::isNotEmpty)
        require(clean == null || (clean.length <= 80 && clean.none(Char::isISOControl))) { "姓名需在 80 字以内" }
        speaker(id).put("name", clean?.let { Secrets.redact(it).text }); store.save()
    }
    fun markMe(id: String) {
        val target = speaker(id)
        store.speakers().forEach { it.put("me", it === target) }
        target.put("ignored", false); store.save()
    }
    fun unmarkMe(id: String) { speaker(id).put("me", false); store.save() }
    fun ignore(id: String, ignored: Boolean) {
        speaker(id).put("ignored", ignored).apply { if (ignored) put("me", false) }; store.save()
    }
    private fun speaker(id: String) = requireNotNull(store.speakers().firstOrNull { it.getString("id") == id }) { "说话人已不存在" }

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
            val s = store.speakers().firstOrNull { it.getString("id") == u.getString("speaker") }
            val name = when {
                s?.optBoolean("me") == true -> "我"
                !s?.optString("name").isNullOrEmpty() -> s!!.getString("name")
                else -> "对方 ${u.getInt("label") }"
            }
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
