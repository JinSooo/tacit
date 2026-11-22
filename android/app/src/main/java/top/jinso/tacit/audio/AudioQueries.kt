package top.jinso.tacit.audio

/** Query paths shared by AudioController and isolated storage tests; caller holds the runtime lock. */
internal class AudioQueries(private val store: EncryptedAudioStore, private val ledger: AudioLedger,
    private val retentionDays: () -> Int, private val sampleAvailable: (String) -> Boolean,
    private val macVoiceprint: () -> top.jinso.tacit.sync.MacVoiceprint? = { null }) {
    /** The Mac already confirmed the user's voice, so the phone never asks "is this you?" again. */
    fun macVoiceKnown(): Boolean = macVoiceprint() != null
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
        return store.speakers().filter {
            val me = isMeSpeaker(it, mac)
            (includeIgnored || !it.optBoolean("ignored")) && (me || it.optString("name").isNotEmpty() ||
                (includeIgnored && it.optBoolean("ignored")) ||
                AudioPolicy.candidate(it.getJSONArray("conversations").length(), it.getDouble("seconds")))
        }.map { s -> AudioSpeaker(s.getString("id"), isMeSpeaker(s, mac), s.optBoolean("ignored"),
            s.getInt("segments"), s.getDouble("seconds"), sampleAvailable(s.getString("id")),
            s.optString("name").takeIf(String::isNotEmpty), s.getJSONArray("conversations").length()) }
    }
}
