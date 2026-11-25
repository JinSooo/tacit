package top.jinso.tacit.audio

internal data class AudioStorageUsage(val clips: Int, val hasVoiceprints: Boolean) {
    val canClear: Boolean get() = clips > 0 || hasVoiceprints
}

/** Query paths shared by AudioController and isolated storage tests; caller holds the runtime lock. */
internal class AudioQueries(private val store: EncryptedAudioStore, private val ledger: AudioLedger,
    private val retentionDays: () -> Int, private val sampledSpeakers: () -> Set<String>,
    private val macVoiceprint: () -> top.jinso.tacit.sync.MacVoiceprint? = { null }) {
    /** The Mac already confirmed the user's voice, so the phone never asks "is this you?" again. */
    fun macVoiceKnown(): Boolean = macVoiceprint() != null
    fun storageUsage(): AudioStorageUsage {
        store.prune(retentionDays())
        return AudioStorageUsage(store.clips().size, store.speakers().isNotEmpty())
    }

    fun listClips(): List<AudioClip> {
        store.prune(retentionDays())
        // Every clip in the index has its PCM: load() drops metadata without audio, deletions drop both.
        return store.clips().map { AudioClip(
            it.getString("id"), it.getLong("start"), it.getInt("samples") * 1000L / SAMPLE_RATE,
            it.getBoolean("analyzed"), it.optString("conversation").takeIf(String::isNotEmpty)) }
    }
    fun listConversations(): List<AudioConversation> {
        ledger.prepare()
        return ledger.listConversations()
    }
    fun listSpeakers(includeIgnored: Boolean = false): List<AudioSpeaker> {
        store.prune(retentionDays())
        ledger.prepare()
        val mac = macVoiceprint()
        val ends = ledger.conversationEnds()
        val sampled = sampledSpeakers()
        return store.speakers().map { it to isMeSpeaker(it, mac) }.filter { (it, me) ->
            (includeIgnored || !it.optBoolean("ignored")) && (me || it.optString("name").isNotEmpty() ||
                (includeIgnored && it.optBoolean("ignored")) ||
                AudioPolicy.candidate(it.getJSONArray("conversations").length(), it.getDouble("seconds")))
        }.map { (s, me) -> AudioSpeaker(s.getString("id"), me, s.optBoolean("ignored"),
            s.getInt("segments"), s.getDouble("seconds"), s.getString("id") in sampled,
            s.optString("name").takeIf(String::isNotEmpty), s.getJSONArray("conversations").length(),
            s.getJSONArray("conversations").let { ids -> (0 until ids.length()).mapNotNull { ends[ids.getString(it)] }.maxOrNull() }) }
    }
}
