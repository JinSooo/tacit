package top.jinso.tacit.audio

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Real Keystore/filesystem, synthetic speech engine: exercises policy without consuming user recordings. */
@RunWith(AndroidJUnit4::class)
class AudioPipelineDeviceTest {
    private fun isolated(run: (EncryptedAudioStore, android.content.Context) -> Unit) {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(base.noBackupFilesDir, "audio-pipeline-${UUID.randomUUID()}")
        val context = object : ContextWrapper(base) { override fun getNoBackupFilesDir() = directory.apply { mkdirs() } }
        try { run(EncryptedAudioStore(context), context) } finally { directory.deleteRecursively() }
    }
    private class FakeSpeech(private val seconds: Int = 1) : SpeechEngine {
        var calls = 0
        override fun segments(pcm: FloatArray): List<VoiceSegment> = (0 until seconds).map { n ->
            val vector = if (pcm[0] > 0.00005f) floatArrayOf(0f, 1f) else floatArrayOf(1f, 0f)
            VoiceSegment(n * SAMPLE_RATE, FloatArray(SAMPLE_RATE) { pcm[0] }, vector)
        }
        override fun transcribe(samples: FloatArray): String { calls++; return "本地文本 ghp_12345678901234567890" }
    }
    private fun add(store: EncryptedAudioStore, time: Long, me: Boolean = false, seconds: Int = 1) =
        store.add(ShortArray(SAMPLE_RATE * seconds) { if (me) 2 else 1 }, time)
    private fun meId(store: EncryptedAudioStore) = store.speakers().first {
        it.getJSONArray("vector").getDouble(1) > .9 }.getString("id")

    private fun seedMe(store: EncryptedAudioStore) {
        store.index.getJSONArray("speakers").put(JSONObject().put("id", "seed-me").put("me", true)
            .put("vector", JSONArray(listOf(0f, 1f))).put("seconds", 0.0).put("segments", 0)
            .put("conversations", JSONArray()))
        store.save()
    }

    @Test fun laterMeBackfillsEarlierClipOnlyInSameConversationWithStableNames() = isolated { store, context ->
        val t = System.currentTimeMillis() - 2_000_000
        val first = add(store, t); val second = add(store, t + 30_000, me = true)
        add(store, t + 700_002)
        val speech = FakeSpeech(); val ledger = AudioLedger(store)
        val publications = mutableListOf<AudioPublication>()
        fun run() = AudioProcessor(store, Any(), speech).drain({ true }) { publications += it; "record:${it.clipId}" }
        run(); assertEquals(0, speech.calls)
        assertEquals(2, ledger.listConversations().size)
        ledger.markMe(meId(store)); run()
        assertEquals(listOf(first, second), publications.map { it.clipId })
        assertEquals(listOf(first, second), ledger.listConversations().single { it.recordIds.isNotEmpty() }.clipIds)
        assertTrue(publications[0].body.startsWith("对方 1："))
        assertTrue(publications[1].body.startsWith("对方 2："))
        assertTrue(ledger.render("record:$second", "missing").startsWith("我："))
        val other = store.speakers().first { it.getString("id") != meId(store) }.getString("id")
        ledger.rename(other, "同事")
        assertTrue(ledger.render("record:$first", "missing").startsWith("同事："))
        assertTrue(publications[0].body.startsWith("对方 1：")) // immutable published body
        assertFalse(ledger.render("record:$first", "missing").contains("ghp_"))
        val restored = EncryptedAudioStore(context)
        assertEquals(ledger.render("record:$first", "missing"), AudioLedger(restored).render("record:$first", "missing"))
        assertFalse(File(context.noBackupFilesDir, "audio/index.enc").readBytes().toString(Charsets.UTF_8).contains("本地文本"))
        run(); assertEquals(2, speech.calls) // no retranscription on rename/retry
    }

    @Test fun candidateCountsConversationsNotVadSpansOrClips() = isolated { store, _ ->
        val t = System.currentTimeMillis() - 2_000_000
        repeat(4) { add(store, t + it * 30_000, seconds = 5) }
        val speech = FakeSpeech(5)
        fun run() = AudioProcessor(store, Any(), speech).drain({ true }) { error("No me: must not publish") }
        run()
        var speaker = store.speakers().single()
        assertEquals(20, speaker.getInt("segments")); assertEquals(1, speaker.getJSONArray("conversations").length())
        assertFalse(AudioPolicy.candidate(speaker.getJSONArray("conversations").length(), speaker.getDouble("seconds")))
        add(store, t + 800_000, seconds = 5); run()
        speaker = store.speakers().single()
        assertEquals(2, speaker.getJSONArray("conversations").length())
        assertTrue(AudioPolicy.candidate(2, speaker.getDouble("seconds")))
        assertEquals(0, speech.calls)
    }

    @Test fun oldMeetingTagAndImportedAudioCannotBypassTheMicrophoneVoicePolicy() = isolated { store, _ ->
        val t = System.currentTimeMillis() - 60_000
        val meeting = add(store, t)
        val imported = add(store, t + 2000, me = true)
        store.clips().first { it.getString("id") == meeting }.put("meeting", "old.meeting")
        store.clips().first { it.getString("id") == imported }.put("origin", "import:old")
        seedMe(store)
        val speech = FakeSpeech()
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Out-of-scope audio must not publish") }
        assertEquals(0, speech.calls)
        assertFalse(store.clips().first { it.getString("id") == imported }.getBoolean("analyzed"))
    }

    @Test fun expiredMeCannotAuthorizeRetainedNeighborsButPublishedTextSurvivesPruneAndClear() = isolated { store, context ->
        val t = System.currentTimeMillis() - 7 * 86_400_000L
        val old = add(store, t - 1000, me = true)
        val kept = add(store, t + 30_000)
        val speech = FakeSpeech(); val ledger = AudioLedger(store)
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unmarked") }
        ledger.markMe(meId(store))
        store.prune(7)
        assertFalse(store.exists(old)); assertTrue(store.exists(kept))
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Expired voice cannot authorize") }
        assertEquals(0, speech.calls)
        // Publish a new microphone recording with me present, then age it past retention.
        val meeting = add(store, System.currentTimeMillis(), me = true)
        AudioProcessor(store, Any(), speech).drain({ true }) { "record:${it.clipId}" }
        val record = "record:$meeting"
        val group = ledger.listConversations().single { record in it.recordIds }.id
        store.clips().first { it.getString("id") == meeting }.put("start", t - 1000)
        store.prune(7)
        assertFalse(store.exists(meeting)); assertTrue(ledger.render(record, "missing").contains("本地文本"))
        store.clear()
        val restored = AudioLedger(EncryptedAudioStore(context))
        assertTrue(restored.render(record, "missing").startsWith("对方 1："))
        assertEquals(group, restored.listConversations().single().id)
        store.deleteRecord(record)
        assertEquals("missing", AudioLedger(store).render(record, "missing"))
        assertTrue(AudioLedger(store).listConversations().isEmpty())
    }

    @Test fun preparedEncryptedTextRecoversWithoutAsrAndDeletionDoesNotBackfill() = isolated { store, context ->
        val id = add(store, System.currentTimeMillis(), me = true)
        seedMe(store)
        val speech = FakeSpeech()
        try {
            AudioProcessor(store, Any(), speech).drain({ true }) { error("Simulated crash before commit") }
            fail("Expected crash")
        } catch (_: IllegalStateException) { }
        val restored = EncryptedAudioStore(context)
        AudioProcessor(restored, Any(), speech).drain({ true }) { "record" }
        assertEquals(1, speech.calls)
        assertTrue(AudioLedger(restored).render("record", "missing").contains("本地文本"))
        restored.deleteRecord("record")
        assertFalse(restored.exists(id))
        AudioProcessor(restored, Any(), speech).drain({ true }) { error("Deleted clip must not be recreated") }
        assertEquals("missing", AudioLedger(restored).render("record", "missing"))
    }

    @Test fun unmarkIgnoreAndPauseRevokePendingBackfill() = isolated { store, _ ->
        val t = System.currentTimeMillis() - 60_000
        add(store, t, me = true)
        val speech = FakeSpeech(); val ledger = AudioLedger(store)
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unmarked") }
        val id = meId(store)
        ledger.markMe(id); ledger.unmarkMe(id)
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Unmarked") }
        ledger.markMe(id); ledger.ignore(id, true)
        AudioProcessor(store, Any(), speech).drain({ true }) { error("Ignored") }
        assertFalse(store.speakers().single().getBoolean("me"))
        ledger.ignore(id, false); ledger.markMe(id)
        AudioProcessor(store, Any(), speech).drain({ false }) { error("Paused") }
        assertEquals(0, speech.calls)
    }

    @Test fun policyRevokedDuringAsrCannotPersistOrPublishReturnedText() = isolated { store, _ ->
        add(store, System.currentTimeMillis(), me = true)
        seedMe(store)
        var active = true
        val fake = FakeSpeech()
        val interrupted = object : SpeechEngine {
            override fun segments(pcm: FloatArray) = fake.segments(pcm)
            override fun transcribe(samples: FloatArray): String {
                active = false
                return "must-not-be-saved"
            }
        }
        AudioProcessor(store, Any(), interrupted).drain({ active }) { error("Permission was revoked") }
        assertFalse(store.index.toString().contains("must-not-be-saved"))
        assertTrue(store.transcripts().isEmpty())
    }


}
