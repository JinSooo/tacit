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

@RunWith(AndroidJUnit4::class)
class AudioQueriesDeviceTest {
    private fun isolated(run: (android.content.Context, EncryptedAudioStore) -> Unit) {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(base.noBackupFilesDir, "audio-query-${UUID.randomUUID()}")
        val context = object : ContextWrapper(base) { override fun getNoBackupFilesDir() = root.apply { mkdirs() } }
        try { run(context, EncryptedAudioStore(context)) } finally { root.deleteRecursively() }
    }
    private fun queries(store: EncryptedAudioStore) = AudioQueries(store, AudioLedger(store), { 7 }, { true })
    private fun legacyFixture(store: EncryptedAudioStore) {
        repeat(2) { n ->
            val id = store.add(ShortArray(SAMPLE_RATE), System.currentTimeMillis() - 60000 + n * 30000)
            store.clips().last().put("analyzed", true).put("utterances", JSONArray().put(JSONObject()
                .put("start", 0).put("length", SAMPLE_RATE).put("speaker", "voice").put("done", true)
                .put("record", "record:$id").put("text", "保留的文字 $n")))
        }
        store.index.getJSONArray("speakers").put(JSONObject().put("id", "voice").put("segments", 20)
            .put("seconds", 20.0).put("vector", JSONArray(listOf(1f, 0f))))
        store.commit(store.clips(), store.speakers())
    }
    private fun stable(file: File, action: () -> Unit) {
        // A fixed old timestamp avoids sleeps and filesystem timestamp-resolution races.
        assertTrue(file.setLastModified(1_600_000_000_000L))
        val modified = file.lastModified(); val bytes = file.readBytes()
        repeat(3) { action() }
        assertEquals("Read refreshed encrypted index mtime", modified, file.lastModified())
        assertArrayEquals("Read rewrote encrypted index bytes", bytes, file.readBytes())
    }
    private fun prepared(run: (File, EncryptedAudioStore, AudioQueries) -> Unit) = isolated { context, store ->
        legacyFixture(store); queries(store).listConversations()
        // Check the first read after a real reload too, not just an in-memory migration cache.
        val reloaded = EncryptedAudioStore(context)
        run(File(context.noBackupFilesDir, "audio/index.enc"), reloaded, queries(reloaded))
    }

    @Test fun clipReadDoesNotRewriteUnexpiredIndex() = prepared { file, _, read ->
        stable(file) { assertEquals(2, read.listClips().size) }
    }
    @Test fun conversationReadDoesNotRewriteMigratedIndex() = prepared { file, store, read ->
        val associations = store.speakers().single().getJSONArray("conversations")
        stable(file) { assertEquals(2, read.listConversations().single().recordIds.size) }
        assertSame(associations, store.speakers().single().getJSONArray("conversations"))
    }
    @Test fun speakerReadDoesNotRewriteUnchangedIndex() = prepared { file, _, read ->
        stable(file) { assertTrue(read.listSpeakers().isEmpty()) }
    }
    @Test fun emptyReadsDoNotCreateAnEncryptedIndex() = isolated { context, store ->
        val read = queries(store)
        repeat(3) {
            assertTrue(read.listClips().isEmpty()); assertTrue(read.listConversations().isEmpty())
            assertTrue(read.listSpeakers().isEmpty()); assertEquals("fallback", AudioLedger(store).render("missing", "fallback"))
        }
        assertFalse(File(context.noBackupFilesDir, "audio/index.enc").exists())
    }
    @Test fun migrationPersistsNewAssociationsOnceAndExpiryStillDeletesRealPcm() = isolated { context, store ->
        legacyFixture(store)
        val file = File(context.noBackupFilesDir, "audio/index.enc"); val legacy = file.readBytes()
        val read = queries(store)
        val conversation = read.listConversations().single()
        assertFalse(legacy.contentEquals(file.readBytes()))
        assertEquals(2, conversation.recordIds.size)
        assertEquals(1, store.speakers().single().getJSONArray("conversations").length())
        stable(file) { read.listConversations(); read.listClips(); read.listSpeakers() }
        val expired = store.clips().first()
        expired.put("start", System.currentTimeMillis() - 8 * 86_400_000L); store.saveClip(expired)
        assertEquals(1, read.listClips().size)
        assertFalse(store.exists(expired.getString("id")))
        assertFalse(File(file.parentFile, "${expired.getString("id")}.meta.enc").exists())
        assertEquals(conversation.recordIds, read.listConversations().single().recordIds)
        stable(file) { read.listClips(); read.listSpeakers(); read.listConversations() }
        val reloaded = EncryptedAudioStore(context)
        assertEquals(2, reloaded.transcripts().size)
        assertTrue(AudioLedger(reloaded).render(conversation.recordIds.first(), "missing").contains("保留的文字"))
    }
    @Test fun orphanPcmCleanupDoesNotRewriteUnchangedMetadata() = prepared { file, store, read ->
        val retained = store.clips().first().getString("id")
        val orphan = File(file.parentFile, "${UUID.randomUUID()}.pcm.enc")
        File(file.parentFile, "$retained.pcm.enc").copyTo(orphan)
        stable(file) { read.listClips() }
        assertFalse(orphan.exists())
    }
}
