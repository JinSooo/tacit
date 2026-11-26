package top.jinso.tacit.audio

import top.jinso.tacit.core.SPEAKER_ME
import top.jinso.tacit.core.speakerNumber
import org.json.JSONArray
import org.json.JSONObject
import top.jinso.tacit.sync.MacVoiceprint
import top.jinso.tacit.core.Secrets
import java.util.UUID

/** A Mac voiceprint only claims a voice heard for at least this long, so one stray short span cannot pass. */
internal const val MAC_ME_MIN_SECONDS = 6.0

internal data class VoiceMarkUndo(val speakerId: String, val locallyMarked: Boolean)

internal fun removeVoiceMark(speaker: JSONObject): VoiceMarkUndo {
    val undo = VoiceMarkUndo(speaker.getString("id"), speaker.optBoolean("me"))
    speaker.put("me", false).put("notMe", true)
    return undo
}

/** Restore a Mac-derived match as a match, without replacing another locally confirmed voice. */
internal fun restoreVoiceMark(speakers: List<JSONObject>, undo: VoiceMarkUndo): JSONObject? {
    val target = speakers.firstOrNull { it.getString("id") == undo.speakerId } ?: return null
    if (!target.optBoolean("notMe") || target.optBoolean("ignored")) return null
    if (undo.locallyMarked && speakers.any { it !== target && it.optBoolean("me") }) return null
    return target.put("me", undo.locallyMarked).apply { remove("notMe") }
}

/**
 * Whether [speaker] is the user: marked "me" on this phone, or a whole voice (its cluster center, never a
 * single utterance) that matches the Mac voiceprint. Labels and transcription consent both use this.
 */
internal fun isMeSpeaker(speaker: JSONObject?, mac: MacVoiceprint?): Boolean {
    if (speaker == null || speaker.optBoolean("ignored") || speaker.optBoolean("notMe")) return false
    if (speaker.optBoolean("me")) return true
    if (mac == null || speaker.optDouble("seconds", 0.0) < MAC_ME_MIN_SECONDS) return false
    val center = speaker.vectorOrNull("vector") ?: return false
    if (center.size != mac.vector.size) return false
    return AudioPolicy.cosine(AudioPolicy.unit(center), AudioPolicy.unit(mac.vector)) >= mac.threshold
}

internal fun transcriptSpeakerLabel(speaker: JSONObject?, mac: MacVoiceprint? = null, number: () -> Int): String {
    if (isMeSpeaker(speaker, mac)) return SPEAKER_ME
    return speaker?.optString("name")?.takeIf(String::isNotEmpty) ?: speakerNumber(number())
}

/** A voice heard this long has a stable center; shorter ones only attach to such voices (as on the Mac). */
internal const val PARTICIPANT_BIG_SECONDS = 6.0
internal const val PARTICIPANT_JOIN = 0.5
internal const val PARTICIPANT_ATTACH = 0.3

internal data class Participant(val number: Int, val center: FloatArray, val seconds: Double)

/**
 * Which participant of this conversation a newly heard voice belongs to, or null for a new one. Per-span voices
 * split one person into dozens (a 3-hour call on 2026-11-22 had 226 "对方"); the Mac re-merges each conversation
 * with the same thresholds (AudioWorkerLogic.consolidate). Short voices join only long participants.
 */
internal fun joinParticipant(participants: List<Participant>, center: FloatArray, seconds: Double,
    join: Double = PARTICIPANT_JOIN, attach: Double = PARTICIPANT_ATTACH): Int? {
    val big = seconds >= PARTICIPANT_BIG_SECONDS
    val v = AudioPolicy.unit(center)
    return participants.filter { it.seconds >= PARTICIPANT_BIG_SECONDS }
        .map { it.number to AudioPolicy.cosine(AudioPolicy.unit(it.center), v) }
        .filter { it.second >= if (big) join else attach }
        .maxByOrNull { it.second }?.first
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
        if (labels.has(speaker)) return labels.getInt(speaker)
        val voices = store.speakers().associateBy { it.getString("id") }
        val numbers = labels.keys().asSequence().map { it to labels.getInt(it) }.toList()
        val participants = numbers.groupBy({ it.second }, { voices[it.first] }).mapNotNull { (number, members) ->
            val known = members.filterNotNull().mapNotNull { m ->
                m.vectorOrNull("vector")?.let { AudioPolicy.unit(it) to m.optDouble("seconds", 0.0) }
            }
            if (known.isEmpty()) return@mapNotNull null
            val size = known.first().first.size
            if (known.any { it.first.size != size }) return@mapNotNull null
            val sum = FloatArray(size)
            for ((v, w) in known) for (i in 0 until size) sum[i] += (v[i] * w).toFloat()
            val seconds = known.sumOf { it.second }
            if (seconds <= 0) null else Participant(number, sum, seconds)
        }
        val own = voices[speaker]
        val center = own?.vectorOrNull("vector")
        val joined = if (center != null && participants.all { it.center.size == center.size })
            joinParticipant(participants, center, own.optDouble("seconds", 0.0)) else null
        labels.put(speaker, joined ?: ((numbers.maxOfOrNull { it.second } ?: 0) + 1))
        return labels.getInt(speaker)
    }

    /** One participant may hold several voices: it is "我" when any of them is, else the first name given to one. */
    private fun participantName(conversation: JSONObject?, number: Int, speaker: String, mac: MacVoiceprint?,
        find: (String) -> JSONObject? = ::findSpeaker, isMe: (JSONObject) -> Boolean = { isMeSpeaker(it, mac) }): String {
        val labels = conversation?.optJSONObject("labels")
        val members = labels?.keys()?.asSequence()?.filter { labels.getInt(it) == number }?.toList().orEmpty()
        val voices = (listOf(speaker) + (members - speaker)).mapNotNull(find)
        if (voices.any(isMe)) return SPEAKER_ME
        return transcriptSpeakerLabel(voices.firstOrNull { it.optString("name").isNotEmpty() } ?: find(speaker), mac) { number }
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
        val conversation = clip.optString("conversation")
        // Judge whole voices, as the Mac does: comparing each short utterance with a low threshold let hours of
        // speaker playback through on a single chance match. Then require enough of "me" in this conversation:
        // short lines from someone else's game or video still join a me voice at the .6 clustering bar.
        val present = voice != null && allowed && conversation.isNotEmpty() && presence.getOrPut(conversation) {
            val speakers = store.speakers().associateBy { it.getString("id") }
            AudioPolicy.mePresent(store.clips().filter { other ->
                other.optString("conversation") == conversation && store.exists(other.getString("id"))
            }.sumOf { other ->
                utterances(other).filter { u -> isMeSpeaker(speakers[u.getString("speaker")], mac) }
                    .sumOf { u -> u.getInt("length").toDouble() / SAMPLE_RATE }
            })
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
        target.remove("notMe")
        target.put("ignored", false); store.saveSpeakers(store.speakers())
    }
    /** Also overrides a Mac voiceprint match, so "this is not me" sticks for a voice the Mac claimed. */
    fun unmarkMe(id: String): VoiceMarkUndo {
        val target = speaker(id)
        val undo = removeVoiceMark(target)
        store.saveSpeakers(listOf(target))
        return undo
    }

    fun undoUnmarkMe(undo: VoiceMarkUndo) {
        val restored = checkNotNull(restoreVoiceMark(store.speakers(), undo)) { "声音标记已变更" }
        store.saveSpeakers(listOf(restored))
    }
    fun ignore(id: String, ignored: Boolean) {
        store.saveSpeakers(listOf(speaker(id).put("ignored", ignored).apply { if (ignored) put("me", false) }))
    }
    private fun findSpeaker(id: String) = store.speakers().firstOrNull { it.getString("id") == id }
    private fun speaker(id: String) = requireNotNull(findSpeaker(id)) { "说话人已不存在" }

    fun transcriptLabel(clip: JSONObject, speakerId: String, mac: MacVoiceprint? = null): String =
        participantName(conversation(clip.getString("conversation")), label(clip, speakerId), speakerId, mac)

    private fun conversation(id: String) = conversations.objects().firstOrNull { it.getString("id") == id }

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

    fun render(record: String, fallback: String, mac: MacVoiceprint? = null): String =
        renderAll(mapOf(record to fallback), mac).getValue(record)

    /**
     * Renders many transcripts with one pass over the index: a long conversation has dozens of records, and looking
     * each one's transcript, conversation and voices up from scratch (and re-deciding "is this me" from the stored
     * vector every line) made opening it take seconds.
     */
    fun renderAll(records: Map<String, String>, mac: MacVoiceprint? = null): Map<String, String> {
        val rows = store.transcripts().filter { it.getString("recordId") in records }.associateBy { it.getString("recordId") }
        val conversationsById by lazy { conversations.objects().associateBy { it.getString("id") } }
        val speakersById by lazy { store.speakers().associateBy { it.getString("id") } }
        val me = HashMap<String, Boolean>()
        val isMe = { voice: JSONObject -> me.getOrPut(voice.getString("id")) { isMeSpeaker(voice, mac) } }
        return records.mapValues { (record, fallback) ->
            val row = rows[record] ?: return@mapValues fallback
            val conversation = conversationsById[row.getString("conversationId")]
            val lines = row.getJSONArray("utterances").objects().mapNotNull { u ->
                // Same rule as publishing: a line of only punctuation ("。") is recognition noise.
                val text = u.optString("text"); if (text.none(Char::isLetterOrDigit)) return@mapNotNull null
                val name = participantName(conversation, u.getInt("label"), u.getString("speaker"), mac,
                    { speakersById[it] }, isMe)
                "$name：$text"
            }
            lines.takeIf { it.isNotEmpty() }?.joinToString("\n") ?: fallback
        }
    }

    /** When each conversation was last heard, without building the full conversation list. */
    fun conversationEnds(): Map<String, Long> {
        val ends = HashMap<String, Long>()
        fun note(id: String, end: Long) { if (id.isNotEmpty()) ends.merge(id, end, ::maxOf) }
        store.transcripts().forEach { note(it.getString("conversationId"), it.getLong("end")) }
        store.clips().forEach { note(it.optString("conversation"), end(it)) }
        return ends
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
