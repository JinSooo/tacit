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
        it.vectorAt("vector")[1] > .9 }.getString("id")

    private fun seedMe(store: EncryptedAudioStore) {
        store.index.getJSONArray("speakers").put(JSONObject().put("id", "seed-me").put("me", true)
            .put("vector", JSONArray(listOf(0f, 1f))).put("seconds", 0.0).put("segments", 0)
            .put("conversations", JSONArray()))
        store.saveSpeakers(store.speakers())
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

    // Regression: one index held every clip and was rewritten in full several times per 30 s clip,
    // so CPU grew with recording time (about 9% of a core after 2 h on the Xiaomi 14 Ultra).
    @Test fun savingOneClipNeverRewritesTheOthers() = isolated { store, context ->
        val t = System.currentTimeMillis() - 3_600_000
        val speech = FakeSpeech()
        fun run() = AudioProcessor(store, Any(), speech).drain({ true }) { error("No me: must not publish") }
        val dir = File(context.noBackupFilesDir, "audio")
        fun metas() = dir.listFiles { f -> f.name.endsWith(".meta.enc") }!!.toList()
        add(store, t); run()
        val head = File(dir, "index.enc").length()
        repeat(40) { add(store, t + (it + 1) * 30_000L) }; run()
        assertTrue("Head must not grow with clips", File(dir, "index.enc").length() < head + 512)
        assertEquals(41, metas().size)
        val old = 1_600_000_000_000L
        metas().forEach { assertTrue(it.setLastModified(old)) }
        val fresh = add(store, t + 41 * 30_000L); run()
        assertEquals(listOf(fresh), metas().filter { it.lastModified() != old }.map { it.name.removeSuffix(".meta.enc") })
        val reloaded = EncryptedAudioStore(context)
        assertEquals(42, reloaded.clips().size)
        assertTrue(reloaded.clips().all { it.getBoolean("analyzed") && it.getJSONArray("utterances").length() == 1 })
    }

    // Regression: clips with no voice were kept for the whole retention period (about 2.7 GB a day).
    @Test fun silentMicrophoneClipIsDeletedOnceAnalyzed() = isolated { store, context ->
        val silent = add(store, System.currentTimeMillis() - 60_000)
        val voiced = add(store, System.currentTimeMillis() - 30_000, me = true)
        val voice = FakeSpeech()
        // Samples of value 1 stand for silence, value 2 for a voice.
        val processor = AudioProcessor(store, Any(), object : SpeechEngine by voice {
            override fun segments(pcm: FloatArray) = if (pcm[0] > 0.00005f) voice.segments(pcm) else emptyList()
        })
        processor.drain({ true }) { error("No me: must not publish") }
        assertFalse(store.exists(silent)); assertTrue(store.exists(voiced))
        assertEquals(listOf(voiced), store.clips().map { it.getString("id") })
        val dir = File(context.noBackupFilesDir, "audio")
        assertFalse(File(dir, "$silent.meta.enc").exists())
        assertEquals(listOf(voiced), EncryptedAudioStore(context).clips().map { it.getString("id") })
    }

    @Test fun layoutOneIndexMigratesIntoClipFilesOnce() = isolated { store, context ->
        val id = add(store, System.currentTimeMillis() - 60_000)
        val dir = File(context.noBackupFilesDir, "audio")
        val metaFile = File(dir, "$id.meta.enc")
        assertTrue(metaFile.delete())
        val legacy = JSONObject()
            .put("clips", JSONArray().put(JSONObject().put("id", id).put("start", 1L).put("samples", SAMPLE_RATE)
                .put("analyzed", true).put("utterances", JSONArray().put(JSONObject().put("start", 0)
                    .put("length", SAMPLE_RATE).put("speaker", "s").put("vector", JSONArray(listOf(0.25f, 0.5f)))))))
            .put("speakers", JSONArray().put(JSONObject().put("id", "s").put("vector", JSONArray(listOf(0f, 1f)))
                .put("seconds", 1.0).put("segments", 1).put("conversations", JSONArray())))
            .put("clips_layout_probe", true)
        store.writeLegacyIndex(legacy.toString().toByteArray())
        val migrated = EncryptedAudioStore(context)
        assertEquals(listOf(id), migrated.clips().map { it.getString("id") })
        assertTrue(metaFile.exists())
        val row = migrated.clips().single().getJSONArray("utterances").getJSONObject(0)
        assertTrue(row.get("vector") is String)
        assertArrayEquals(floatArrayOf(0.25f, 0.5f), row.vectorAt("vector"), 0f)
        assertArrayEquals(floatArrayOf(0f, 1f), migrated.speakers().single().vectorAt("vector"), 0f)
        // The head no longer lists clips or voices: without their files nothing brings them back.
        assertTrue(metaFile.delete()); assertTrue(File(dir, "s.speaker.enc").delete())
        assertTrue(EncryptedAudioStore(context).clips().isEmpty())
        assertTrue(EncryptedAudioStore(context).speakers().isEmpty())
        assertTrue(EncryptedAudioStore(context).index.optBoolean("clips_layout_probe"))
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
