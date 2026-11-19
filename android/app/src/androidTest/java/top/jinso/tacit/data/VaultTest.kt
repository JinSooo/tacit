package top.jinso.tacit.data

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import top.jinso.tacit.core.Draft
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sources.WECHAT_PACKAGE
import net.zetetic.database.sqlcipher.SQLiteDatabase
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class VaultTest {
    private fun isolated():Context {
        val base=InstrumentationRegistry.getInstrumentation().targetContext
        val unique="test-"+UUID.randomUUID()
        return object:ContextWrapper(base) {
            override fun getNoBackupFilesDir():File=File(base.noBackupFilesDir,unique).apply{mkdirs()}
            override fun getSharedPreferences(name:String,mode:Int)=base.getSharedPreferences("$unique-$name",mode)
        }
    }
    @Test fun encryptedRoundTripRedactionDedupCorrectionAndTrueDelete() {
        val context=isolated();val prefs=Preferences(context);prefs.setEnabled("android.notification",true)
        var vault=Vault(context,prefs)
        try {
            val secret="sk-"+"abcdefghijklmnop1234567890"
            val draft=Draft("android.notification","test-secret","内容 $secret",sourceRef="repeat",app="test.app")
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
    @Test fun disabledPausedAndBlockedSourcesNeverPersist() {
        val context=isolated();val prefs=Preferences(context);val vault=Vault(context,prefs)
        try {
            val draft=Draft(Sources.USAGE,"title","body",app="test.blocked")
            assertNull(vault.ingest(draft));prefs.setEnabled(draft.source,true);prefs.paused=true;assertNull(vault.ingest(draft))
            assertNotNull(vault.ingest(Draft("manual.note","手动","暂停时仍可补写",method="manual")))
            prefs.paused=false;prefs.blockedApps=setOf("test.blocked");assertNull(vault.ingest(draft))
            assertEquals(1L,vault.count())
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
            prefs.setPause(true, System.currentTimeMillis()-1)
            assertFalse(prefs.paused)
            prefs.setPause(true, 0)
            assertTrue(prefs.paused)
            assertNotNull(vault.ingest(Draft("system.pause","采集已暂停","暂停期间不自动记录。",method="manual")))
        } finally {vault.close();context.noBackupFilesDir.deleteRecursively()}
    }

    @Test fun chatSelectionDefaultsToWeChatAndExplicitEmptySelectionSurvivesReopen() {
        val context = isolated()
        val prefs = Preferences(context)
        prefs.setEnabled(Sources.NOTIFICATION, true)
        assertEquals(setOf(WECHAT_PACKAGE), prefs.chatApps)
        assertTrue(prefs.allowsChatNotification(WECHAT_PACKAGE))
        assertFalse(prefs.allowsChatNotification("test.chat"))
        prefs.chatApps = setOf("test.chat")
        assertTrue(prefs.allowsChatNotification("test.chat"))
        assertFalse(prefs.allowsChatNotification(WECHAT_PACKAGE))
        prefs.blockedApps = setOf("test.chat")
        assertFalse(prefs.allowsChatNotification("test.chat"))
        prefs.chatApps = emptySet()
        assertTrue(Preferences(context).chatApps.isEmpty())
        context.noBackupFilesDir.deleteRecursively()
    }

    @Test fun legacyRecordsRemainLocalAndTheirCorrectionsCannotEnterSync() {
        val context = isolated()
        val prefs = Preferences(context)
        prefs.setEnabled(Sources.NOTIFICATION, true)
        prefs.setEnabled(Sources.AUDIO, true)
        try {
            val (oldChat, oldAudio, removed) = Vault(context, prefs).let { vault ->
                try {
                    Triple(
                        vault.ingest(Draft(Sources.NOTIFICATION, "旧通知", "旧正文"))!!,
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
                val current = vault.ingest(Draft(Sources.NOTIFICATION, "项目组", "小李：新消息", sourceRef = "new-chat"))!!
                val correction = vault.ingest(Draft(Sources.CORRECTION, "修正", "更新", corrects = current))!!
                assertEquals(vault.wire(current), vault.uploadableWire(current))
                assertEquals(vault.wire(correction), vault.uploadableWire(correction))
            } finally { vault.close() }
        } finally { context.noBackupFilesDir.deleteRecursively() }
    }

}
