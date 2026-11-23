package top.jinso.tacit.audio

import android.content.ContextWrapper
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

/**
 * Version 2 files use a Keystore-wrapped data key (2026-11-23: per-file Keystore decryption made the first
 * index load take ~24 s on a real phone). Real Keystore and filesystem, synthetic content, isolated dirs.
 */
@RunWith(AndroidJUnit4::class)
class AudioStoreEncryptionDeviceTest {
    private fun isolated(run: (android.content.Context, File) -> Unit) {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(base.noBackupFilesDir, "audio-encryption-${UUID.randomUUID()}")
        val context = object : ContextWrapper(base) { override fun getNoBackupFilesDir() = root.apply { mkdirs() } }
        try { run(context, File(root, "audio")) } finally { root.deleteRecursively() }
    }
    private fun clip(id: String, start: Long) = JSONObject().put("id", id).put("start", start)
        .put("samples", 1600).put("analyzed", false).put("utterances", JSONArray())
    private fun pcm(start: Short) = ByteArray(3200) { if (it % 2 == 0) start.toByte() else 0 }

    @Test fun version1FilesStillReadAndSmallFilesMigrateOnLoad() = isolated { context, dir ->
        val now = System.currentTimeMillis()
        val legacy = EncryptedAudioStore(context)
        val old = UUID.randomUUID().toString()
        legacy.writeVersion1("$old.pcm.enc", pcm(7))
        legacy.writeVersion1("$old.meta.enc", clip(old, now - 60_000).toString().toByteArray())
        legacy.writeVersion1("voice-a.speaker.enc", JSONObject().put("id", "voice-a").put("me", true).toString().toByteArray())
        legacy.writeVersion1("index.enc", JSONObject().put("transcripts", JSONArray()).toString().toByteArray())

        val store = EncryptedAudioStore(context)
        assertEquals(listOf(old), store.clips().map { it.getString("id") })
        assertEquals(listOf("voice-a"), store.speakers().map { it.getString("id") })
        // Item files and the head are rewritten as version 2; PCM keeps version 1 and still decrypts.
        assertEquals(2, store.versionOf("$old.meta.enc"))
        assertEquals(2, store.versionOf("voice-a.speaker.enc"))
        assertEquals(2, store.versionOf("index.enc"))
        assertEquals(1, store.versionOf("$old.pcm.enc"))
        assertEquals(7 / 32768f, store.pcm(old)[0])
        // New recordings are version 2 and a fresh instance reads the mix.
        val fresh = store.add(ShortArray(1600) { 3 }, now)
        assertEquals(2, store.versionOf("$fresh.pcm.enc"))
        val reopened = EncryptedAudioStore(context)
        assertEquals(setOf(old, fresh), reopened.clips().map { it.getString("id") }.toSet())
        assertEquals(3 / 32768f, reopened.pcm(fresh)[0])
        assertTrue(File(dir, "data-key.wrap").isFile)
    }

    @Test fun lostWrappedKeyNeverMintsAReplacement() = isolated { context, dir ->
        val store = EncryptedAudioStore(context)
        val id = store.add(ShortArray(1600) { 1 }, System.currentTimeMillis())
        assertTrue(File(dir, "data-key.wrap").delete())
        val error = runCatching { EncryptedAudioStore(context).pcm(id) }.exceptionOrNull()
        assertTrue("$error", error is IllegalStateException && error.message == "录音密钥不可用，原文件已保留")
        assertFalse(File(dir, "data-key.wrap").exists())
        assertTrue(File(dir, "$id.pcm.enc").isFile)
    }

    @Test fun concurrentFirstUseAgreesOnOneDataKey() = isolated { context, _ ->
        val stores = List(4) { EncryptedAudioStore(context) }
        val go = CountDownLatch(1)
        val ids = arrayOfNulls<String>(stores.size)
        val workers = stores.mapIndexed { n, store ->
            thread { go.await(); ids[n] = store.add(ShortArray(1600) { n.toShort() }, System.currentTimeMillis() + n) }
        }
        go.countDown(); workers.forEach { it.join() }
        val reader = EncryptedAudioStore(context)
        ids.forEachIndexed { n, id -> assertEquals(n / 32768f, reader.pcm(id!!)[0]) }
    }

    @Test fun loadAfterMigrationAvoidsPerFileKeystoreWork() = isolated { context, _ ->
        val now = System.currentTimeMillis()
        val legacy = EncryptedAudioStore(context)
        repeat(300) { n ->
            val id = UUID.randomUUID().toString()
            legacy.writeVersion1("$id.pcm.enc", pcm(1))
            legacy.writeVersion1("$id.meta.enc", clip(id, now - n * 1000L).toString().toByteArray())
        }
        val t0 = System.nanoTime()
        assertEquals(300, EncryptedAudioStore(context).clips().size)
        val migrating = (System.nanoTime() - t0) / 1_000_000
        val t1 = System.nanoTime()
        assertEquals(300, EncryptedAudioStore(context).clips().size)
        val migrated = (System.nanoTime() - t1) / 1_000_000
        Log.i("TacitAudioStore", "load 300 items: version1=${migrating}ms version2=${migrated}ms")
        assertTrue("version 2 load took ${migrated}ms", migrated < 2_000)
    }
}
