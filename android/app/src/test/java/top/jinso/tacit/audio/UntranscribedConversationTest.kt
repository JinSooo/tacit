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

        override fun deleteConversationAudio(conversationId: String): DeleteConversationAudioResult {
            val hasTranscripts = transcripts().any { it.getString("conversationId") == conversationId }
            val selected = clips().filter { clip ->
                clip.optString("conversation") == conversationId &&
                    clip.getJSONArray("utterances").objects().none { it.optString("record").isNotEmpty() }
            }.map { it.getString("id") }.toSet()
            if (selected.isEmpty()) {
                return if (hasTranscripts) DeleteConversationAudioResult.ALREADY_TRANSCRIBED
                else DeleteConversationAudioResult.NOT_FOUND
            }
            if (hasTranscripts) {
                index.optJSONArray("conversations")?.objects()
                    ?.firstOrNull { it.getString("id") == conversationId }
                    ?.let { conv ->
                        val confirmed = conv.optJSONArray("userConfirmedClips")
                        if (confirmed != null) {
                            val remaining = (0 until confirmed.length()).map { confirmed.getString(it) }
                                .filterNot { it in selected }
                            if (remaining.isEmpty()) conv.remove("userConfirmedClips")
                            else conv.put("userConfirmedClips", JSONArray(remaining))
                        }
                    }
            }
            selected.forEach { pcmData.remove(it); clipMeta.remove(it) }
            index.put("clips", JSONArray(clips().filterNot { it.getString("id") in selected }))
            if (!hasTranscripts) {
                val remaining = index.optJSONArray("conversations")?.objects()
                    ?.filterNot { it.getString("id") == conversationId }
                if (remaining != null) index.put("conversations", JSONArray(remaining))
            }
            save()
            return DeleteConversationAudioResult.DELETED
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

        // Confirm only the target conversation's explicit clips and reload from serialized JSON to verify persistence.
        ledger.confirmConversation(target.id, target.untranscribedClipIds.toSet())
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
        val conv = ledger.listConversations().single()
        ledger.confirmConversation(conv.id, conv.untranscribedClipIds.toSet())

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
        val conv = ledger.listConversations().single()
        ledger.confirmConversation(conv.id, conv.untranscribedClipIds.toSet())
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
            ledger.confirmConversation(id, setOf(clipId))
            fail("Expired clip must not be confirmable")
        } catch (_: IllegalArgumentException) { }
        try {
            ledger.confirmConversation(id, emptySet())
            fail("Empty clip set must be rejected")
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

        val deleteResult = store.deleteConversationAudio(convA)
        assertEquals(DeleteConversationAudioResult.DELETED, deleteResult)
        assertEquals(DeleteConversationAudioResult.NOT_FOUND, store.deleteConversationAudio(convA))
        store.reload()

        assertFalse(store.exists(clipA))
        assertTrue(store.exists(clipB))
        assertEquals(listOf(convB), AudioLedger(store).listConversations().map { it.id })
    }

    @Test fun confirmingClipDoesNotAuthorizeLaterClipsAttachedToSameConversation() {
        val store = FakeAudioStore()
        val now = System.currentTimeMillis()
        val firstClip = store.addClip(now - 300_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        val speech = FakeSpeech()
        val published = mutableListOf<AudioPublication>()

        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        val ledger = AudioLedger(store)
        val convId = ledger.listConversations().single().id

        // Confirm batch 1, transcribe, and reload index from disk.
        ledger.confirmConversation(convId, setOf(firstClip))
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        assertEquals(listOf(firstClip), published.map { it.clipId })
        assertTrue(store.speakers().none { it.optBoolean("me") })

        store.reload()

        // Add a second clip 1 minute later (within 10-minute adjacency window -> attaches to same conversation).
        val laterClip = store.addClip(now - 240_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }

        val reloadedLedger = AudioLedger(store)
        val conv = reloadedLedger.listConversations().single()
        assertEquals(convId, conv.id)
        assertTrue(laterClip in conv.clipIds)
        // Later clip MUST NOT be transcribed without a new explicit confirmation or "me" voiceprint.
        assertEquals(listOf(firstClip), published.map { it.clipId })
        assertTrue(conv.hasUntranscribedClips)
        assertTrue(conv.untranscribedAudioAvailable)
        assertFalse(conv.userConfirmed)
        assertFalse(conv.transcribePending)
        assertTrue(store.speakers().none { it.optBoolean("me") })
    }

    @Test fun deleteRaceReportsAlreadyTranscribedAndSkipPreventsPublishWhenDeleteWins() {
        // Order A: background drain publishes first -> subsequent delete reports ALREADY_TRANSCRIBED without claiming DELETED.
        val storeA = FakeAudioStore()
        val now = System.currentTimeMillis()
        val clipA = storeA.addClip(now - 120_000L, FloatArray(SAMPLE_RATE * 3) { 0.2f })
        val speechA = FakeSpeech()
        val statuses = mutableListOf<Pair<String, ManualTranscriptionStatus?>>()
        AudioProcessor(storeA, Any(), speechA).drain({ true }) { error("Unconfirmed") }
        val ledgerA = AudioLedger(storeA)
        val convA = ledgerA.listConversations().single().id
        ledgerA.confirmConversation(convA, setOf(clipA))
        AudioProcessor(storeA, Any(), speechA).drain(
            allowed = { true },
            onManualStatus = { id, status -> statuses += id to status },
        ) { "rec:${it.clipId}" }
        assertEquals(listOf(convA to ManualTranscriptionStatus.RUNNING, convA to null), statuses)
        assertEquals(DeleteConversationAudioResult.ALREADY_TRANSCRIBED, storeA.deleteConversationAudio(convA))
        assertEquals(listOf("rec:$clipA"), storeA.transcripts().map { it.getString("recordId") })

        // Order B: pending delete beats queued drain -> skipConversation stops publish and delete removes audio.
        val storeB = FakeAudioStore()
        val clipB = storeB.addClip(now - 120_000L, FloatArray(SAMPLE_RATE * 3) { 0.2f })
        val speechB = FakeSpeech()
        val publishedB = mutableListOf<AudioPublication>()
        AudioProcessor(storeB, Any(), speechB).drain({ true }) { error("Unconfirmed") }
        val ledgerB = AudioLedger(storeB)
        val convB = ledgerB.listConversations().single().id
        ledgerB.confirmConversation(convB, setOf(clipB))
        AudioProcessor(storeB, Any(), speechB).drain(
            allowed = { true },
            skipConversation = { it == convB },
        ) { publishedB += it; "rec:${it.clipId}" }
        assertTrue(publishedB.isEmpty())
        assertEquals(0, speechB.transcribeCalls)
        assertEquals(DeleteConversationAudioResult.DELETED, storeB.deleteConversationAudio(convB))
        assertFalse(storeB.exists(clipB))
    }

    @Test fun restoreIgnoredCandidatesReEnablesSkippedPlayableVoices() {
        val store = FakeAudioStore()
        val clipId = store.addClip(System.currentTimeMillis() - 60_000L, FloatArray(SAMPLE_RATE * 3) { 0.2f })
        AudioProcessor(store, Any(), FakeSpeech()).drain({ true }) { error("Unconfirmed") }
        val ledger = AudioLedger(store)
        val speakerId = store.speakers().single().getString("id")
        ledger.ignore(speakerId, true)
        assertTrue(store.speakers().single().optBoolean("ignored"))

        assertEquals(1, ledger.restoreIgnoredCandidates())
        assertFalse(store.speakers().single().optBoolean("ignored"))
        assertTrue(store.exists(clipId))
    }

    @Test fun retryAfterFailureDoesNotExpandAuthorizationToLaterClips() {
        val store = FakeAudioStore()
        val now = System.currentTimeMillis()
        val firstClip = store.addClip(now - 300_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        var shouldFailAsr = false
        val speech = FakeSpeech {
            if (shouldFailAsr) throw IllegalStateException("Injected ASR failure")
            "失败后重试的首批转写"
        }
        val published = mutableListOf<AudioPublication>()

        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        val ledger = AudioLedger(store)
        val conv = ledger.listConversations().single()
        assertEquals(listOf(firstClip), conv.untranscribedClipIds)

        // Confirm first clip, inject ASR failure, reload index.
        ledger.confirmConversation(conv.id, conv.untranscribedClipIds.toSet())
        shouldFailAsr = true
        try {
            AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
            fail("Expected ASR failure")
        } catch (_: IllegalStateException) { }
        store.reload()

        // A second clip arrives 1 minute later and attaches to the same conversation without "me" voice.
        val laterClip = store.addClip(now - 240_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        shouldFailAsr = true
        try {
            AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        } catch (_: IllegalStateException) { }

        // User taps Retry -> must ONLY re-queue previously confirmed clip, NEVER authorize laterClip!
        val reloaded = AudioLedger(store)
        val retriedIds = reloaded.retryConfirmedClips(conv.id)
        assertEquals(setOf(firstClip), retriedIds)
        store.reload()

        shouldFailAsr = false
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        assertEquals(listOf(firstClip), published.map { it.clipId })
        assertTrue(store.speakers().none { it.optBoolean("me") })

        val after = AudioLedger(store).listConversations().single()
        assertEquals(conv.id, after.id)
        assertEquals(listOf(laterClip), after.untranscribedClipIds)
        assertTrue(after.hasUntranscribedClips)
        assertFalse(after.userConfirmed)
        assertFalse(after.transcribePending)
    }

    @Test fun confirmingExplicitClipSetDoesNotSweepInInterleavedAttachedClip() {
        val store = FakeAudioStore()
        val now = System.currentTimeMillis()
        val firstClip = store.addClip(now - 300_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        val speech = FakeSpeech()
        val published = mutableListOf<AudioPublication>()

        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        val ledger = AudioLedger(store)
        val uiSnapshot = ledger.listConversations().single()
        val selectedClipIds = uiSnapshot.untranscribedClipIds.toSet()
        assertEquals(setOf(firstClip), selectedClipIds)

        // Before the user's confirm executes on worker, a second clip gets analyzed and attached to the same conversation.
        val interleavedClip = store.addClip(now - 240_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }

        // Confirming with the UI snapshot's explicit clipIds only authorizes firstClip.
        val authorized = ledger.confirmConversation(uiSnapshot.id, selectedClipIds)
        assertEquals(setOf(firstClip), authorized)
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        assertEquals(listOf(firstClip), published.map { it.clipId })

        val after = ledger.listConversations().single()
        assertEquals(listOf(interleavedClip), after.untranscribedClipIds)
        assertTrue(after.hasUntranscribedClips)
        assertFalse(after.userConfirmed)
    }

    @Test fun partiallyTranscribedConversationTracksUntranscribedTimeRangeAcrossMidnight() {
        val store = FakeAudioStore()
        val zone = java.time.ZoneId.systemDefault()
        val clipAStart = java.time.LocalDateTime.of(2026, 11, 25, 23, 55, 0).atZone(zone).toInstant().toEpochMilli()
        val clipBStart = java.time.LocalDateTime.of(2026, 11, 26, 0, 2, 0).atZone(zone).toInstant().toEpochMilli()
        val clipA = store.addClip(clipAStart, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        val speech = FakeSpeech()
        val published = mutableListOf<AudioPublication>()

        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        val ledger = AudioLedger(store)
        val convId = ledger.listConversations().single().id
        ledger.confirmConversation(convId, setOf(clipA))
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }

        // Clip B attaches across midnight (7 min later) and stays untranscribed.
        val clipB = store.addClip(clipBStart, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }

        val conv = ledger.listConversations().single()
        assertEquals(convId, conv.id)
        assertEquals(listOf(clipB), conv.untranscribedClipIds)
        assertEquals(clipBStart, conv.untranscribedStart)
        assertEquals(clipBStart + 5_000L, conv.untranscribedEnd)
        assertEquals(
            java.time.LocalDate.of(2026, 11, 26),
            java.time.Instant.ofEpochMilli(conv.untranscribedStart!!).atZone(zone).toLocalDate(),
        )

        // Sample preview and deletion target clip B (Day 2), leaving clip A's published transcript intact.
        val sample = pickConversationSample(store.clips(), convId, store::exists, untranscribedOnly = true)
        assertEquals(clipB, sample?.first)
        assertEquals(DeleteConversationAudioResult.DELETED, store.deleteConversationAudio(convId))
        assertFalse(store.exists(clipB))
        assertEquals(listOf("rec:$clipA"), store.transcripts().map { it.getString("recordId") })
    }

    @Test fun expiredFailedClipClearsPendingStateSoRemainingNewClipCanBeConfirmed() {
        val store = FakeAudioStore()
        val now = System.currentTimeMillis()
        val clip1 = store.addClip(now - 300_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        var failAsr = true
        val speech = FakeSpeech {
            if (failAsr) throw IllegalStateException("ASR error")
            "第二段新确认的转写"
        }
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unconfirmed") }
        val ledger = AudioLedger(store)
        val convId = ledger.listConversations().single().id
        ledger.confirmConversation(convId, setOf(clip1))
        try {
            AudioProcessor(store, Any(), speech).drain({ true }) { error("Should fail ASR") }
        } catch (_: IllegalStateException) { }

        // A second clip attaches, then the old failed clip expires and its PCM disappears.
        val clip2 = store.addClip(now - 240_000L, FloatArray(SAMPLE_RATE * 5) { 0.2f })
        try {
            AudioProcessor(store, Any(), speech).drain({ true }) { error("Should fail ASR on clip1") }
        } catch (_: IllegalStateException) { }
        store.dropPcm(clip1)
        store.reload()

        val afterExpiry = AudioLedger(store).listConversations().single()
        assertEquals(convId, afterExpiry.id)
        assertFalse(afterExpiry.transcribePending)
        assertFalse(afterExpiry.userConfirmed)
        assertTrue(afterExpiry.untranscribedAudioAvailable)
        assertEquals(listOf(clip2), afterExpiry.untranscribedClipIds)
        assertTrue(AudioLedger(store).pendingConfirmedConversationIds().isEmpty())

        // User can explicitly confirm clip2 now that clip1 expired.
        AudioLedger(store).confirmConversation(convId, afterExpiry.untranscribedClipIds.toSet())
        failAsr = false
        val published = mutableListOf<AudioPublication>()
        AudioProcessor(store, Any(), speech).drain({ true }) { published += it; "rec:${it.clipId}" }
        assertEquals(listOf(clip2), published.map { it.clipId })
    }
}
