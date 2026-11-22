package top.jinso.tacit.data

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.json.JSONObject
import top.jinso.tacit.core.Ids
import top.jinso.tacit.sync.Change
import org.junit.Test
import org.junit.runner.RunWith
import top.jinso.tacit.core.Draft
import top.jinso.tacit.sources.Sources
import net.zetetic.database.sqlcipher.SQLiteDatabase
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class VaultTest {
    private val base get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val created=mutableListOf<Pair<String,MutableSet<String>>>()
    private fun isolated():Context {
        val unique="test-"+UUID.randomUUID()
        val names=mutableSetOf<String>().also { created+=unique to it }
        return object:ContextWrapper(base) {
            override fun getNoBackupFilesDir():File=File(base.noBackupFilesDir,unique).apply{mkdirs()}
            override fun getSharedPreferences(name:String,mode:Int)=base.getSharedPreferences("$unique-$name".also(names::add),mode)
        }
    }
    // Isolated stores must not pile up in the real app's data directory (110 were left on a test phone).
    @org.junit.After fun removeIsolatedStores() {
        for ((unique,names) in created) {
            File(base.noBackupFilesDir,unique).deleteRecursively()
            names.forEach(base::deleteSharedPreferences)
        }
        created.clear()
    }
    @Test fun encryptedRoundTripRedactionDedupCorrectionAndTrueDelete() {
        val context=isolated();val prefs=Preferences(context);prefs.setEnabled(Sources.AUDIO,true)
        var vault=Vault(context,prefs)
        try {
            val secret="sk-"+"abcdefghijklmnop1234567890"
            val draft=Draft(Sources.AUDIO,"test-secret","内容 $secret",sourceRef="repeat")
            val id=vault.ingest(draft)!!
            assertEquals(id,vault.ingest(draft))
            assertEquals(id,vault.ingest(draft.copy(body="different retry text")))
            assertFalse(vault.get(id)!!.body.contains("different retry text"))
            assertEquals(1L,vault.count())
            assertEquals("redacted",vault.get(id)!!.sensitivity)
            assertFalse(vault.get(id)!!.body.contains(secret))
            val correction=vault.ingest(Draft("manual.correction","更正","用户更正",corrects=id,method="manual"))!!
            val second=vault.ingest(Draft("manual.correction","再更正","第二次更正",corrects=correction,method="manual"))!!
            vault.close();vault=Vault(context,prefs)
            assertEquals(3L,vault.count());assertNotNull(vault.get(second))
            val bytes=File(context.noBackupFilesDir,"history.db").readBytes().toString(Charsets.ISO_8859_1)
            assertFalse(bytes.startsWith("SQLite format 3"));assertFalse(bytes.contains("test-secret"));assertFalse(bytes.contains(secret))
            assertEquals(3,vault.delete(id));assertEquals(0L,vault.count())
            assertNull(vault.ingest(draft))
            vault.close();vault=Vault(context,prefs);assertEquals(0L,vault.count());assertNull(vault.ingest(draft))
        } finally {vault.close();context.noBackupFilesDir.deleteRecursively()}
    }
    // 手机只录音（0.4.2）：旧版本的聊天通知、应用使用即使开关还开着，也不能再写进新记录。
    @Test fun onlyEnabledRecordingAndManualRecordsPersist() {
        val context=isolated();val prefs=Preferences(context);val vault=Vault(context,prefs)
        try {
            val audio=Draft(Sources.AUDIO,"title","body")
            assertNull(vault.ingest(audio));prefs.setEnabled(Sources.AUDIO,true);assertNotNull(vault.ingest(audio))
            for (legacy in listOf(Sources.NOTIFICATION, Sources.USAGE)) {
                prefs.setEnabled(legacy,true)
                assertNull(vault.ingest(Draft(legacy,"旧来源","不再采集",app="test.app")))
            }
            assertNotNull(vault.ingest(Draft("manual.note","手动","手动记录",method="manual")))
            assertEquals(2L,vault.count())
        } finally {vault.close();context.noBackupFilesDir.deleteRecursively()}
    }
    @Test fun missingWrappedKeyDoesNotReplaceExistingDatabase() {
        val context=isolated();val prefs=Preferences(context);val vault=Vault(context,prefs)
        vault.ingest(Draft("manual.note","keep","preserve this data",method="manual"));vault.close()
        val file=File(context.noBackupFilesDir,"history.db");val original=file.readBytes()
        File(context.noBackupFilesDir,"vault.key").delete()
        try {Vault(context,prefs);fail("Must fail closed")}catch(_:IllegalStateException){}
        assertArrayEquals(original,file.readBytes());assertFalse(File(context.noBackupFilesDir,"vault.key").exists())
        context.noBackupFilesDir.deleteRecursively()
    }
    @Test fun corruptedDatabaseIsPreservedInsteadOfAutomaticallyDeleted() {
        val context=isolated();val prefs=Preferences(context);val vault=Vault(context,prefs)
        vault.ingest(Draft("manual.note","keep","do not replace",method="manual"));vault.close()
        val file=File(context.noBackupFilesDir,"history.db")
        val damaged=file.readBytes().also{bytes->for(i in 0 until minOf(64,bytes.size))bytes[i]=0}
        file.writeBytes(damaged)
        try {Vault(context,prefs);fail("Must reject corrupted ciphertext")}catch(_:android.database.sqlite.SQLiteException){}
        assertTrue(file.exists());assertArrayEquals(damaged,file.readBytes())
        context.noBackupFilesDir.deleteRecursively()
    }

    @Test fun keyAtomicBackupIsRecoveredWithoutReplacingTheDatabase() {
        val context=isolated();val prefs=Preferences(context);var vault=Vault(context,prefs)
        try {
            val id=vault.ingest(Draft("manual.note","keep","key backup recovery",method="manual"))!!
            vault.close()
            val key=File(context.noBackupFilesDir,"vault.key")
            assertTrue(key.renameTo(File(key.path+".bak")))
            vault=Vault(context,prefs)
            assertEquals("key backup recovery",vault.get(id)!!.body)
            assertTrue(key.exists())
        } finally {vault.close();context.noBackupFilesDir.deleteRecursively()}
    }
    @Test fun sourceDateFiltersAndCorrectionNavigationAreBounded() {
        val context=isolated();val prefs=Preferences(context);val vault=Vault(context,prefs)
        try {
            val original=vault.ingest(Draft("manual.note","early","one",start=1000,method="manual"))!!
            val fix=vault.ingest(Draft("manual.correction","fix","two",start=2000,method="manual",corrects=original))!!
            val latest=vault.ingest(Draft("manual.correction","latest","three",start=3000,method="manual",corrects=fix))!!
            assertEquals(listOf(fix),vault.list(from=2000,until=3000).map{it.id})
            assertTrue(vault.list(source="android.audio").isEmpty())
            assertEquals(listOf(fix,latest),vault.corrections(original).map{it.id})
            assertEquals(listOf("manual.correction", "manual.note"),vault.sources())
        } finally {vault.close();context.noBackupFilesDir.deleteRecursively()}
    }

    @Test fun legacyRecordsRemainLocalAndTheirCorrectionsCannotEnterSync() {
        val context = isolated()
        val prefs = Preferences(context)
        prefs.setEnabled(Sources.AUDIO, true)
        try {
            val (oldChat, oldAudio, removed) = Vault(context, prefs).let { vault ->
                try {
                    Triple(
                        vault.ingest(Draft(Sources.AUDIO, "旧通知", "旧正文", sourceRef = "old-chat"))!!,
                        vault.ingest(Draft(Sources.AUDIO, "旧录音", "旧转写"))!!,
                        vault.ingest(Draft(Sources.NOTE, "旧屏幕记录", "仅本地"))!!,
                    )
                } finally { vault.close() }
            }
            val file = File(context.noBackupFilesDir, "history.db")
            val key = Keys(context).databaseKey(true)
            try {
                SQLiteDatabase.openOrCreateDatabase(file, key, null, null).use { db ->
                    db.execSQL("ALTER TABLE records DROP COLUMN capture_scope")
                    db.execSQL("UPDATE records SET source = 'android.screen' WHERE id = ?", arrayOf(removed))
                    db.execSQL("UPDATE records SET source = '${Sources.NOTIFICATION}' WHERE id = ?", arrayOf(oldChat))
                }
            } finally { key.fill(0) }
            val vault = Vault(context, prefs)
            try {
                for (id in listOf(oldChat, oldAudio, removed)) {
                    assertNotNull(vault.get(id))
                    assertNotNull(vault.wire(id))
                    assertNull(vault.uploadableWire(id))
                    val correction = vault.ingest(Draft(Sources.CORRECTION, "修正", "保留", corrects = id))!!
                    assertNull(vault.uploadableWire(correction))
                    assertEquals(2, vault.delete(id))
                }
                prefs.setEnabled("android.screen", true)
                assertNull(vault.ingest(Draft("android.screen", "旧来源", "不可继续采集")))
                val current = vault.ingest(Draft(Sources.AUDIO, "一场对话", "我：新录音", sourceRef = "new-audio"))!!
                val correction = vault.ingest(Draft(Sources.CORRECTION, "修正", "更新", corrects = current))!!
                assertEquals(vault.wire(current), vault.uploadableWire(current))
                assertEquals(vault.wire(correction), vault.uploadableWire(correction))
            } finally { vault.close() }
        } finally { context.noBackupFilesDir.deleteRecursively() }
    }

    @Test fun syncStateSurvivesReopenAndRemoteChangesAreIdempotent() {
        val context = isolated()
        val prefs = Preferences(context)
        val pairedId = "android-aebagbaf"
        val draft = Draft(Sources.NOTE, "补写", "用于同步测试", sourceRef = "synthetic-ref", method = "manual")
        val (original, rejected, deleted) = Vault(context, prefs).let { vault ->
            try {
                val original = vault.ingest(draft)!!
                val rejected = vault.ingest(draft.copy(sourceRef = null))!!
                val deleted = vault.ingest(draft.copy(sourceRef = null))!!
                vault.saveSyncConnection(JSONObject().put("device", pairedId))
                val batch = vault.uploadBatch(pairedId)
                assertEquals(listOf(original, rejected, deleted), batch.map { it.first })
                assertEquals(pairedId, batch.first().second.getString("device"))
                assertEquals(prefs.device, JSONObject(vault.wire(original)!!).getString("device"))
                vault.applyReceipt(batch.map { it.first }, mapOf(1 to "测试拒绝"))
                assertEquals(1, vault.delete(deleted))
                Triple(original, rejected, deleted)
            } finally { vault.close() }
        }
        val vault = Vault(context, prefs)
        try {
            assertEquals(listOf(deleted), vault.pendingDeletes())
            assertEquals(mapOf("测试拒绝" to 1), vault.rejectedReasons(includeReasons = true))
            assertEquals(0, vault.pendingCount())
            val originalWire = JSONObject(vault.wire(original)!!)
            val fix = JSONObject(originalWire.toString()).apply {
                put("id", Ids.next())
                put("source", Sources.CORRECTION)
                put("corrects", original)
                put("device", "mac")
                put("body", "Mac 修正")
                remove("source_ref")
            }
            val correction = Change.Correction(fix)
            repeat(2) { vault.applyChanges(listOf(correction)) }
            assertEquals("Mac 修正", vault.corrections(original).single().body)
            assertTrue(vault.uploadBatch(pairedId).isEmpty())
            val removal = Change.Delete(original, Sources.NOTE, originalWire.getString("source_ref"))
            repeat(2) { vault.applyChanges(listOf(removal, correction)) }
            assertNull(vault.get(original))
            assertNull(vault.get(fix.getString("id")))
            assertNull(vault.ingest(draft))
            assertNotNull(vault.get(rejected))
            assertEquals(listOf(deleted), vault.pendingDeletes())
            vault.confirmDeletes(listOf(deleted))
            assertTrue(vault.pendingDeletes().isEmpty())
        } finally {
            vault.close()
            context.noBackupFilesDir.deleteRecursively()
        }
    }
}
