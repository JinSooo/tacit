package top.jinso.tacit.data

import android.content.ContentValues
import android.content.Context
import net.zetetic.database.sqlcipher.SQLiteDatabase
import top.jinso.tacit.core.*
import top.jinso.tacit.sources.Sources
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

class Vault(context: Context, private val prefs: Preferences) {
    private val db: SQLiteDatabase
    private val hasLegacySummaries: Boolean
    val changes = MutableStateFlow(0L)
    init {
        System.loadLibrary("sqlcipher")
        val file = File(context.noBackupFilesDir, "history.db")
        val key = Keys(context).databaseKey(file.exists())
        try { db = SQLiteDatabase.openOrCreateDatabase(file, key, null, net.zetetic.database.DatabaseErrorHandler { _, error -> throw error }) }
        finally { key.fill(0) }
        db.rawQuery("PRAGMA secure_delete=ON", emptyArray<String>()).use { check(it.moveToFirst() && it.getInt(0)==1) }
        db.rawQuery("PRAGMA journal_mode=DELETE", emptyArray<String>()).use { check(it.moveToFirst() && it.getString(0).equals("delete",ignoreCase=true)) }
        db.execSQL("CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, source TEXT NOT NULL, ref TEXT, title TEXT NOT NULL, body TEXT NOT NULL, start INTEGER NOT NULL, end INTEGER, app TEXT, sensitivity TEXT NOT NULL, corrects TEXT, redactions INTEGER NOT NULL, wire TEXT NOT NULL, UNIQUE(source,ref))")
        db.execSQL("CREATE INDEX IF NOT EXISTS by_time ON records(start DESC)")
        db.execSQL("CREATE INDEX IF NOT EXISTS corrections ON records(corrects)")
        db.execSQL("CREATE TABLE IF NOT EXISTS tombstones(hash TEXT PRIMARY KEY)")
        val hasCaptureScope = db.rawQuery("PRAGMA table_info(records)", emptyArray<String>()).use { cursor ->
            val name = cursor.getColumnIndexOrThrow("name")
            var present = false
            while (cursor.moveToNext()) if (cursor.getString(name) == "capture_scope") present = true
            present
        }
        if (!hasCaptureScope) db.execSQL("ALTER TABLE records ADD COLUMN capture_scope INTEGER NOT NULL DEFAULT 0")
        // An upgraded vault may contain old derived text. Preserve its delete/correction invalidation.
        hasLegacySummaries = db.rawQuery(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('conversation_summaries','summary_sources')",
            emptyArray<String>(),
        ).use { it.moveToFirst() && it.getInt(0) == 2 }
    }
    /** Same source/ref returns its original ID, so an interrupted audio publish can finish its metadata.
     * Permission and tombstone rejection still return null; duplicates never rewrite the original. */
    @Synchronized fun ingest(draft: Draft): String? {
        val manual = draft.source in setOf(Sources.NOTE, Sources.CORRECTION, "system.pause")
        if (!manual && (draft.source !in Sources.UPLOADABLE || !prefs.allows(draft.source, draft.app))) return null
        require(draft.source.matches(Regex("[a-z0-9_]+(\\.[a-z0-9_]+)+")))
        require(draft.body.length <= 200000 && draft.title.isNotBlank())
        require(draft.end == null || draft.end >= draft.start)
        require(draft.method in setOf("ax","ocr","asr","db","file","hook","api","manual"))
        require((draft.source == Sources.CORRECTION) == (draft.corrects != null))
        if (draft.corrects != null) require(get(draft.corrects) != null) { "原记录已删除" }
        val ref = draft.sourceRef?.let { hash(prefs.device + ":" + draft.source + ":" + it) }
        if (ref != null && db.rawQuery("SELECT 1 FROM tombstones WHERE hash=?", arrayOf(hash(draft.source + ":" + ref))).use { it.moveToFirst() }) return null
        val filteredTitle = Secrets.redact(draft.title)
        val titlePoints = filteredTitle.text.replace(Regex("\\s+"), " ").codePoints().limit(200).toArray()
        val title = filteredTitle.copy(text=String(titlePoints,0,titlePoints.size))
        val body = Secrets.redact(draft.body)
        val app = draft.app?.let { Secrets.redact(it) }
        val redactions = title.count + body.count + (app?.count ?: 0)
        val sensitivity = if (draft.private) "private" else if (redactions > 0) "redacted" else "normal"
        val id = Ids.next()
        val wire = JSONObject().put("schema", 1).put("id", id).put("device", prefs.device).put("source", draft.source)
            .put("title", title.text).put("body", body.text).put("kind", if (draft.end == null) "event" else "span")
            .put("t_start", iso(draft.start)).put("sensitivity", sensitivity).put("redactions", redactions)
            .put("capture", JSONObject().put("method", draft.method))
        draft.end?.let { wire.put("t_end", iso(it)) }
        app?.let { wire.put("context", JSONObject().put("app", it.text)) }
        ref?.let { wire.put("source_ref", it) }
        draft.corrects?.let { wire.put("corrects", it) }
        val values = ContentValues().apply {
            put("id",id); put("source",draft.source); put("ref",ref); put("title",title.text); put("body",body.text)
            put("start",draft.start); put("end",draft.end); put("app",app?.text); put("sensitivity",sensitivity)
            put("corrects",draft.corrects); put("redactions",redactions); put("wire",wire.toString())
            put("capture_scope", CHAT_AND_MICROPHONE_SCOPE)
        }
        val row = db.insertWithOnConflict("records",null,values,SQLiteDatabase.CONFLICT_IGNORE)
        if (row == -1L) return ref?.let {
            db.rawQuery("SELECT id FROM records WHERE source=? AND ref=?", arrayOf(draft.source,it)).use { c -> if(c.moveToFirst())c.getString(0) else null }
        }
        draft.corrects?.let { invalidateSummaries(it) }
        changes.value++; return id
    }
    @Synchronized fun list(query: String = "", source: String? = null, limit: Int = 500, from: Long? = null, until: Long? = null): List<HistoryRecord> {
        val where = mutableListOf("1=1"); val args = mutableListOf<String>()
        if(query.isNotBlank()) { where += "(instr(lower(title),lower(?))>0 OR instr(lower(body),lower(?))>0)"; args += query; args += query }
        if(source != null) { where += "source=?"; args += source }
        if(from != null) { where += "start>=?"; args += from.toString() }
        if(until != null) { where += "start<?"; args += until.toString() }
        return db.rawQuery("SELECT id,source,title,body,start,end,app,sensitivity,corrects,redactions FROM records WHERE ${where.joinToString(" AND ")} ORDER BY start DESC,id DESC LIMIT ${limit.coerceAtLeast(1)}",args.toTypedArray()).use { cursor ->
            buildList { while(cursor.moveToNext()) add(HistoryRecord(cursor.getString(0),cursor.getString(1),cursor.getString(2),cursor.getString(3),cursor.getLong(4),if(cursor.isNull(5)) null else cursor.getLong(5),cursor.getString(6),cursor.getString(7),cursor.getString(8),cursor.getInt(9))) }
        }
    }
    @Synchronized fun get(id: String): HistoryRecord? = db.rawQuery("SELECT id,source,title,body,start,end,app,sensitivity,corrects,redactions FROM records WHERE id=?", arrayOf(id)).use { c ->
        if(!c.moveToFirst()) null else HistoryRecord(c.getString(0),c.getString(1),c.getString(2),c.getString(3),c.getLong(4),if(c.isNull(5)) null else c.getLong(5),c.getString(6),c.getString(7),c.getString(8),c.getInt(9))
    }
    @Synchronized fun sources(): List<String> = db.rawQuery("SELECT DISTINCT source FROM records ORDER BY source", emptyArray<String>()).use { c ->
        buildList { while(c.moveToNext()) add(c.getString(0)) }
    }
    @Synchronized fun corrections(id: String): List<HistoryRecord> {
        val ids = mutableListOf(id)
        val result = mutableListOf<HistoryRecord>()
        var i = 0
        while(i < ids.size) {
            db.rawQuery("SELECT id FROM records WHERE corrects=? ORDER BY start,id", arrayOf(ids[i++])).use { c ->
                while(c.moveToNext()) if(c.getString(0) !in ids) { ids += c.getString(0); get(c.getString(0))?.let { result += it } }
            }
        }
        return result
    }
    @Synchronized fun count(): Long = db.rawQuery("SELECT count(*) FROM records", emptyArray<String>()).use { it.moveToFirst(); it.getLong(0) }
    @Synchronized fun wire(id: String): String? = db.rawQuery("SELECT wire FROM records WHERE id=?", arrayOf(id)).use { if(it.moveToFirst()) it.getString(0) else null }
    /** Wire payload for future sync. Raw local records remain available through list/get/wire. */
    @Synchronized fun uploadableWire(id: String): String? {
        var current: String? = id
        while (current != null) {
            val (source, parent, scope) = db.rawQuery(
                "SELECT source,corrects,capture_scope FROM records WHERE id=?", arrayOf(current),
            ).use { c ->
                if (!c.moveToFirst()) return null
                Triple(c.getString(0), c.getString(1), c.getInt(2))
            }
            if (source !in Sources.UPLOADABLE) return null
            // 0.3 used the same source IDs for general notifications and imported/meeting audio.
            if ((source == Sources.AUDIO || source == Sources.NOTIFICATION) && scope < CHAT_AND_MICROPHONE_SCOPE) return null
            if ((source == Sources.CORRECTION) != (parent != null)) return null
            current = parent
        }
        return wire(id)
    }

    @Synchronized fun delete(id: String): Int {
        val ids = mutableListOf(id)
        var index = 0
        while(index < ids.size) {
            db.rawQuery("SELECT id FROM records WHERE corrects=?", arrayOf(ids[index++])).use { while(it.moveToNext()) { val child = it.getString(0); if(child !in ids) ids += child } }
        }
        var deleted = 0
        db.beginTransaction()
        try {
            for(target in ids) {
                invalidateSummaries(target)
                db.rawQuery("SELECT source,ref FROM records WHERE id=?", arrayOf(target)).use { c ->
                    if(c.moveToFirst() && !c.isNull(1)) db.insertWithOnConflict("tombstones",null,ContentValues().apply { put("hash",hash(c.getString(0)+":"+c.getString(1))) },SQLiteDatabase.CONFLICT_IGNORE)
                }
                deleted += db.delete("records","id=?",arrayOf(target))
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        db.execSQL("VACUUM")
        changes.value++; return deleted
    }
    private fun invalidateSummaries(recordId: String) {
        if (!hasLegacySummaries) return
        db.execSQL("DELETE FROM conversation_summaries WHERE id IN (SELECT summary_id FROM summary_sources WHERE record_id=?)", arrayOf(recordId))
        db.execSQL("DELETE FROM summary_sources WHERE summary_id NOT IN (SELECT id FROM conversation_summaries)")
    }
    @Synchronized fun close() { db.close() }
    private companion object { const val CHAT_AND_MICROPHONE_SCOPE = 1 }

    private fun hash(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
}
