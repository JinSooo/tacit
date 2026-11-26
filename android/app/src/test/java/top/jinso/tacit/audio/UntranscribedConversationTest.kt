package top.jinso.tacit.audio

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class UntranscribedConversationTest {
    private class FakeAudioStore : AudioStore {
        private var headJson: String = JSONObject().toString()
        private val clipMeta = LinkedHashMap<String, String>()
        private val speakerMeta = LinkedHashMap<String, String>()
        private val pcmData = LinkedHashMap<String, FloatArray>()
        private var loaded: JSONObject? = null

        override val index: JSONObject
            get() = loaded ?: reload()

        fun reload(): JSONObject {
            val head = JSONObject(headJson)
            val clips = clipMeta.values.map { JSONObject(it) }
                .filter { pcmData.containsKey(it.getString("id")) }
                .sortedBy { it.getLong("start") }
            val speakers = speakerMeta.values.map { JSONObject(it) }
                .sortedWith(compareBy({ it.optLong("order") }, { it.getString("id") }))
            return head.put("clips", JSONArray(clips)).put("speakers", JSONArray(speakers)).also { loaded = it }
        }

        fun addClip(start: Long, samples: FloatArray): String {
            val id = UUID.randomUUID().toString()
            pcmData[id] = samples.copyOf()
            val clip = JSONObject().put("id", id).put("start", start)
                .put("samples", samples.size).put("analyzed", false).put("utterances", JSONArray())
            index.getJSONArray("clips").put(clip)
            clipMeta[id] = clip.toString()
            return id
        }

        fun dropPcm(clipId: String) {
            pcmData.remove(clipId)
        }

        override fun clips(): List<JSONObject> = index.getJSONArray("clips").objects()
        override fun speakers(): List<JSONObject> = index.getJSONArray("speakers").objects()
        override fun transcripts(): List<JSONObject> = index.optJSONArray("transcripts")?.objects().orEmpty()
        override fun exists(id: String): Boolean = pcmData.containsKey(id)
        override fun pcm(id: String): FloatArray = checkNotNull(pcmData[id]).copyOf()

        override fun discard(clipId: String) {
            pcmData.remove(clipId)
            clipMeta.remove(clipId)
            index.put("clips", JSONArray(clips().filterNot { it.getString("id") == clipId }))
            save()
        }

        override fun prune(days: Int) {
            val now = System.currentTimeMillis()
            val (drop, keep) = clips().partition { AudioPolicy.expired(it.getLong("start"), now, days) }
            if (drop.isEmpty()) return
            index.put("clips", JSONArray(keep))
            drop.forEach { val id = it.getString("id"); pcmData.remove(id); clipMeta.remove(id) }
        }

        override fun save(vararg clips: JSONObject) = commit(clips.toList())

        override fun commit(clips: Collection<JSONObject>, speakers: Collection<JSONObject>) {
            val names = index.keys().asSequence().filter { it != "clips" && it != "speakers" }.toList().toTypedArray()
            headJson = JSONObject(index, names).toString()
            clips.forEach(::saveClip)
            saveSpeakers(speakers)
        }

        override fun saveClip(clip: JSONObject) {
            clipMeta[clip.getString("id")] = clip.toString()
        }

        override fun saveSpeakers(speakers: Collection<JSONObject>) {
            speakers.forEach { speakerMeta[it.getString("id")] = it.toString() }
        }

        override fun deleteConversationAudio(conversationId: String) {
            val hasTranscripts = transcripts().any { it.getString("conversationId") == conversationId }
            val selected = clips().filter { clip ->
                clip.optString("conversation") == conversationId &&
                    clip.getJSONArray("utterances").objects().none { it.optString("record").isNotEmpty() }
            }.map { it.getString("id") }.toSet()
            if (selected.isEmpty()) return
            selected.forEach { pcmData.remove(it); clipMeta.remove(it) }
            index.put("clips", JSONArray(clips().filterNot { it.getString("id") in selected }))
            if (!hasTranscripts) {
                val remaining = index.optJSONArray("conversations")?.objects()
                    ?.filterNot { it.getString("id") == conversationId }
                if (remaining != null) index.put("conversations", JSONArray(remaining))
            }
            save()
        }
    }

    private class FakeSpeech(private val reply: () -> String = { "这是一段确认补转写的对话" }) : SpeechEngine {
        var transcribeCalls = 0
        override fun segments(pcm: FloatArray): List<VoiceSegment> {
            val vector = if (pcm[0] > 0.5f) floatArrayOf(1f, 0f) else floatArrayOf(0f, 1f)
            return listOf(VoiceSegment(0, pcm.copyOf(), vector))
        }

        override fun transcribe(samples: FloatArray): String {
            transcribeCalls++
            return reply()
        }
    }

    @Test fun userConfirmedPolicyStillRespectsAllowedFlag() {
        assertTrue(AudioPolicy.conversationAllowed(meMarked = false, mePresentInRetainedAudio = false, allowed = true, userConfirmed = true))
        assertFalse(AudioPolicy.conversationAllowed(meMarked = false, mePresentInRetainedAudio = false, allowed = false, userConfirmed = true))
        assertFalse(AudioPolicy.conversationAllowed(meMarked = false, mePresentInRetainedAudio = false, allowed = true, userConfirmed = false))
    }

    @Test fun confirmingOneConversationTranscribesItWithoutPollutingMeVoiceprint() {
        val store = FakeAudioStore()
        val now = System.currentTimeMillis()
        val firstClip = store.addClip(now - 900_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        val secondClip = store.addClip(now - 60_000L, FloatArray(SAMPLE_RATE * 5) { 0.8f })
        val speech = FakeSpeech()
        val ledger = AudioLedger(store)
        val queries = AudioQueries(store, ledger, { 7 }, { emptySet() })
        val published = mutableListOf<AudioPublication>()

        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        assertEquals(0, speech.transcribeCalls)
        assertTrue(published.isEmpty())

        val before = queries.listConversations()
        assertEquals(2, before.size)
        assertTrue(before.all { it.recordIds.isEmpty() && it.audioAvailable && !it.userConfirmed && !it.transcribePending })
        val target = before.single { firstClip in it.clipIds }
        val untouched = before.single { secondClip in it.clipIds }
        assertTrue(queries.conversationAudioAvailable(target.id))

        // Confirm only the target conversation and reload from serialized JSON to verify persistence.
        ledger.confirmConversation(target.id)
        store.reload()
        val reloadedLedger = AudioLedger(store)
        val reloadedQueries = AudioQueries(store, reloadedLedger, { 7 }, { emptySet() })

        assertTrue(reloadedLedger.isConversationConfirmed(target.id))
        assertFalse(reloadedLedger.isConversationConfirmed(untouched.id))
        val queued = reloadedQueries.listConversations().single { it.id == target.id }
        assertTrue(queued.userConfirmed)
        assertTrue(queued.transcribePending)

        // None of the speakers may be marked as "me".
        assertTrue(store.speakers().none { it.optBoolean("me") })
        assertNull(reloadedLedger.meVoice())

        // Drain without any "me" voice or Mac voiceprint: only the confirmed conversation transcribes.
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        assertEquals(listOf(firstClip), published.map { it.clipId })
        assertEquals(1, speech.transcribeCalls)
        assertTrue(published.single().body.contains("对方 1：这是一段确认补转写的对话"))
        assertTrue(store.speakers().none { it.optBoolean("me") })
        assertNull(reloadedLedger.meVoice())

        val after = reloadedQueries.listConversations()
        val doneTarget = after.single { it.id == target.id }
        val stillUntranscribed = after.single { it.id == untouched.id }
        assertEquals(listOf("rec:$firstClip"), doneTarget.recordIds)
        assertFalse(doneTarget.transcribePending)
        assertTrue(stillUntranscribed.recordIds.isEmpty())
        assertFalse(stillUntranscribed.userConfirmed)
    }

    @Test fun confirmedConversationRecoversAfterCrashWithoutReRunningAsr() {
        val store = FakeAudioStore()
        val clipId = store.addClip(System.currentTimeMillis() - 60_000L, FloatArray(SAMPLE_RATE * 3) { 0.2f })
        val speech = FakeSpeech()
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unconfirmed") }
        val ledger = AudioLedger(store)
        val conversationId = ledger.listConversations().single().id
        ledger.confirmConversation(conversationId)

        try {
            AudioProcessor(store, Any(), speech).drain({ true }) { error("Simulated publish crash") }
            fail("Expected publish crash")
        } catch (_: IllegalStateException) { }
        assertEquals(1, speech.transcribeCalls)

        // Reload persisted state and retry: prepared text publishes without running ASR again.
        store.reload()
        val published = mutableListOf<AudioPublication>()
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        assertEquals(1, speech.transcribeCalls)
        assertEquals(listOf(clipId), published.map { it.clipId })
    }

    @Test fun punctuationOnlyAsrClearsPendingState() {
        val store = FakeAudioStore()
        store.addClip(System.currentTimeMillis() - 60_000L, FloatArray(SAMPLE_RATE * 2) { 0.2f })
        val speech = FakeSpeech { "。。。" }
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unconfirmed") }
        val ledger = AudioLedger(store)
        val id = ledger.listConversations().single().id
        ledger.confirmConversation(id)
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Punctuation must not publish") }

        val after = ledger.listConversations().single()
        assertTrue(after.recordIds.isEmpty())
        assertTrue(after.userConfirmed)
        assertFalse(after.transcribePending)
    }

    @Test fun confirmingExpiredConversationFailsClearly() {
        val store = FakeAudioStore()
        val clipId = store.addClip(System.currentTimeMillis() - 60_000L, FloatArray(SAMPLE_RATE * 2) { 0.2f })
        val speech = FakeSpeech()
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unconfirmed") }
        val ledger = AudioLedger(store)
        val id = ledger.listConversations().single().id
        store.dropPcm(clipId)

        assertFalse(ledger.conversationAudioAvailable(id))
        try {
            ledger.confirmConversation(id)
            fail("Expired clip must not be confirmable")
        } catch (_: IllegalArgumentException) { }
    }

    @Test fun pickConversationSampleChoosesLongestRetainedUtteranceCappedAtTenSeconds() {
        val shortClip = JSONObject().put("id", "c1").put("conversation", "conv-a").put("samples", SAMPLE_RATE * 15)
            .put("utterances", JSONArray()
                .put(JSONObject().put("start", 0).put("length", SAMPLE_RATE * 2))
                .put(JSONObject().put("start", SAMPLE_RATE * 2).put("length", SAMPLE_RATE * 12)))
        val otherClip = JSONObject().put("id", "c2").put("conversation", "conv-b").put("samples", SAMPLE_RATE * 20)
            .put("utterances", JSONArray().put(JSONObject().put("start", 0).put("length", SAMPLE_RATE * 20)))

        val picked = pickConversationSample(listOf(shortClip, otherClip), "conv-a", exists = { it == "c1" })
        assertEquals(Triple("c1", SAMPLE_RATE * 2, SAMPLE_RATE * 12), picked)

        // When audio no longer exists, returns null.
        assertNull(pickConversationSample(listOf(shortClip, otherClip), "conv-a", exists = { false }))
    }

    @Test fun deletingUntranscribedConversationRemovesOnlyItsAudioAndPreservesOthers() {
        val store = FakeAudioStore()
        val now = System.currentTimeMillis()
        val clipA = store.addClip(now - 900_000L, FloatArray(SAMPLE_RATE * 3) { 0.2f })
        val clipB = store.addClip(now - 60_000L, FloatArray(SAMPLE_RATE * 3) { 0.8f })
        val speech = FakeSpeech()
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unconfirmed") }
        val ledger = AudioLedger(store)
        val convA = ledger.listConversations().single { clipA in it.clipIds }.id
        val convB = ledger.listConversations().single { clipB in it.clipIds }.id

        store.deleteConversationAudio(convA)
        store.reload()

        assertFalse(store.exists(clipA))
        assertTrue(store.exists(clipB))
        assertEquals(listOf(convB), AudioLedger(store).listConversations().map { it.id })
    }
}
