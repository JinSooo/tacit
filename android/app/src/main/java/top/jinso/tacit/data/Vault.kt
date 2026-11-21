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
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import top.jinso.tacit.sync.Change
import top.jinso.tacit.sync.optionalString
import top.jinso.tacit.sync.sendingCopy
import top.jinso.tacit.sync.MAX_ENVELOPE

class Vault(context: Context, private val prefs: Preferences, private val onSendableChange: () -> Unit = {}) {
    private val db: SQLiteDatabase
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
        // NULL send state identifies pre-sync and newly captured records awaiting eligibility checks.
        transaction {
            db.execSQL("CREATE TABLE IF NOT EXISTS sync_connection (slot INTEGER PRIMARY KEY CHECK(slot=1), data TEXT NOT NULL)")
            db.execSQL("CREATE TABLE IF NOT EXISTS sync_records (id TEXT PRIMARY KEY, state TEXT NOT NULL, reason TEXT)")
            db.execSQL("CREATE TABLE IF NOT EXISTS sync_deletes (id TEXT PRIMARY KEY)")
        }
        // 0.3 的手机端整理已撤下，派生文本不再展示，也不再维护：升级时直接删掉。
        db.execSQL("DROP TABLE IF EXISTS summary_sources")
        db.execSQL("DROP TABLE IF EXISTS conversation_summaries")
    }
    /** Same source/ref returns its original ID, so an interrupted audio publish can finish its metadata.
     * Permission and tombstone rejection still return null; duplicates never rewrite the original. */
    fun ingest(draft: Draft): String? = ingest(draft, ZoneOffset.UTC)

    @Synchronized internal fun ingest(draft: Draft, offset: ZoneOffset): String? {
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
        fun time(value: Long): String = if (offset == ZoneOffset.UTC) iso(value)
            else Instant.ofEpochMilli(value).atOffset(offset).format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)
        val wire = JSONObject().put("schema", 1).put("id", id).put("device", prefs.device).put("source", draft.source)
            .put("title", title.text).put("body", body.text).put("kind", if (draft.end == null) "event" else "span")
            .put("t_start", time(draft.start)).put("sensitivity", sensitivity).put("redactions", redactions)
            .put("capture", JSONObject().put("method", draft.method))
        draft.end?.let { wire.put("t_end", time(it)) }
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
        changes.value++
        if (draft.source in Sources.UPLOADABLE && syncConnection()?.optBoolean("removed") == false) onSendableChange()
        return id
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
    /** Wire payload for sync. Raw local records remain available through list/get/wire. */
    @Synchronized fun uploadableWire(id: String): String? {
        var current: String? = id
        val seen = mutableSetOf<String>()
        while (current != null) {
            if (!seen.add(current) || hasTombstone("id:" + current)) return null
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
        val enqueue = syncConnection()?.optBoolean("removed") == false
        val count = transaction { deleteTree(id, enqueue) }
        db.execSQL("VACUUM")
        changes.value++
        if (enqueue && count != 0) onSendableChange()
        return count
    }

    private fun deleteTree(id: String, enqueue: Boolean): Int {
        val ids = listOf(id) + corrections(id).map { it.id }
        // Evaluate eligibility before deleting the parent of a correction.
        if (enqueue) for (target in ids) {
            if (uploadableWire(target) != null && syncState(target) !in setOf("rejected", "remote", "local")) {
                db.execSQL("INSERT OR IGNORE INTO sync_deletes(id) VALUES(?)", arrayOf(target))
            }
        }
        var count = 0
        for (target in ids) {
            tombstone("id:" + target)
            db.rawQuery("SELECT source,ref FROM records WHERE id=?", arrayOf(target)).use { c ->
                if (c.moveToFirst() && !c.isNull(1)) tombstone(c.getString(0) + ":" + c.getString(1))
            }
            db.delete("sync_records", "id=?", arrayOf(target))
            if (!enqueue) db.delete("sync_deletes", "id=?", arrayOf(target))
            count += db.delete("records", "id=?", arrayOf(target))
        }
        return count
    }

    internal fun audioSourceRef(clipId: String): String = hash(prefs.device + ":" + Sources.AUDIO + ":audio:" + clipId)

    private fun hasTombstone(key: String): Boolean =
        db.rawQuery("SELECT 1 FROM tombstones WHERE hash=?", arrayOf(hash(key))).use { it.moveToFirst() }

    private fun tombstone(key: String) {
        db.execSQL("INSERT OR IGNORE INTO tombstones(hash) VALUES(?)", arrayOf(hash(key)))
    }

    private inline fun <T> transaction(block: () -> T): T {
        db.beginTransaction()
        try {
            val result = block()
            db.setTransactionSuccessful()
            return result
        } finally { db.endTransaction() }
    }

    @Synchronized internal fun syncConnection(): JSONObject? =
        db.rawQuery("SELECT data FROM sync_connection WHERE slot=1", emptyArray<String>()).use {
            if (it.moveToFirst()) JSONObject(it.getString(0)) else null
        }

    @Synchronized internal fun saveSyncConnection(data: JSONObject?) {
        transaction {
            if (data == null || data.optString("device") != syncConnection()?.optString("device")) {
                db.delete("sync_deletes", null, null)
            }
            if (data == null) db.delete("sync_connection", null, null)
            else db.execSQL("INSERT OR REPLACE INTO sync_connection VALUES(1,?)", arrayOf(data.toString()))
        }
        changes.value++
    }

    private fun syncState(id: String): String? =
        db.rawQuery("SELECT state FROM sync_records WHERE id=?", arrayOf(id)).use {
            if (it.moveToFirst()) it.getString(0) else null
        }

    private fun pendingIds(limit: Int): List<String> {
        val sources = Sources.UPLOADABLE
        val placeholders = sources.joinToString(",") { "?" }
        return db.rawQuery(
            """SELECT records.id FROM records LEFT JOIN sync_records USING(id)
               WHERE sync_records.id IS NULL AND source IN ($placeholders)
               ORDER BY records.rowid LIMIT ?""", (sources.toList() + limit.toString()).toTypedArray(),
        ).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }
    }

    @Synchronized internal fun uploadBatch(device: String): List<Pair<String, JSONObject>> = buildList {
        var bytes = 0
        // Base64url expansion, timestamp, nonce and JSON framing also count toward the limit.
        val bodyBudget = (MAX_ENVELOPE - 1024) / 4 * 3
        while (size < 200) {
            val candidates = pendingIds(200).filter { candidate -> none { it.first == candidate } }
            if (candidates.isEmpty()) break
            for (id in candidates) {
                val wire = uploadableWire(id)
                if (wire == null) {
                    setSyncState(id, "local")
                    continue
                }
                val copy = sendingCopy(wire, device)
                val length = copy.toString().toByteArray().size + 1
                if (length > bodyBudget) {
                    setSyncState(id, "rejected", "记录太大，无法发送")
                    continue
                }
                if (bytes + length > bodyBudget) return@buildList
                add(id to copy)
                bytes += length
                if (size == 200) return@buildList
            }
        }
    }

    private fun setSyncState(id: String, state: String, reason: String? = null) {
        db.execSQL("INSERT OR REPLACE INTO sync_records VALUES(?,?,?)", arrayOf(id, state, reason))
    }

    @Synchronized internal fun applyReceipt(ids: List<String>, rejected: Map<Int, String>) {
        transaction {
            ids.forEachIndexed { position, id ->
                if (wire(id) != null) {
                    val reason = rejected[position]
                    setSyncState(id, if (reason == null) "confirmed" else "rejected", reason)
                }
            }
        }
        changes.value++
    }

    @Synchronized internal fun pendingDeletes(): List<String> =
        db.rawQuery("SELECT id FROM sync_deletes ORDER BY rowid LIMIT 100", emptyArray<String>()).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0)) }
        }

    @Synchronized internal fun confirmDeletes(ids: List<String>) = transaction {
        ids.forEach { db.delete("sync_deletes", "id=?", arrayOf(it)) }
    }

    @Synchronized internal fun pendingCount(): Int = pendingIds(-1).count { uploadableWire(it) != null }

    @Synchronized internal fun rejectedReasons(includeReasons: Boolean): Map<String, Int> = db.rawQuery(
        if (includeReasons) "SELECT reason,count(*) FROM sync_records WHERE state='rejected' GROUP BY reason ORDER BY count(*) DESC"
        else "SELECT '',count(*) FROM sync_records WHERE state='rejected'",
        emptyArray<String>(),
    ).use { c -> buildMap { while (c.moveToNext()) put(c.getString(0), c.getInt(1)) } }

    @Synchronized internal fun applyChanges(page: List<Change>) {
        transaction {
            for (change in page) when (change) {
                is Change.Delete -> {
                    if (change.source != null && change.ref != null) tombstone(change.source + ":" + change.ref)
                    deleteTree(change.id, enqueue = false)
                }
                is Change.Correction -> insertRemoteCorrection(change.record)
            }
        }
        if (page.isNotEmpty()) changes.value++
    }

    private fun insertRemoteCorrection(record: JSONObject) {
        val id = record.getString("id")
        val parent = record.getString("corrects")
        if (wire(id) != null || hasTombstone("id:" + id) || hasTombstone("id:" + parent)) return
        check(record.getString("source") == Sources.CORRECTION)
        val ref = record.optionalString("source_ref")
        if (ref != null && hasTombstone(Sources.CORRECTION + ":" + ref)) return
        val values = ContentValues().apply {
            put("id", id)
            put("source", Sources.CORRECTION)
            put("ref", ref)
            put("title", record.getString("title"))
            put("body", record.getString("body"))
            put("start", Instant.parse(record.getString("t_start")).toEpochMilli())
            put("end", record.optionalString("t_end")?.let { Instant.parse(it).toEpochMilli() })
            put("app", record.optJSONObject("context")?.optionalString("app"))
            put("sensitivity", record.getString("sensitivity"))
            put("corrects", parent)
            put("redactions", record.optInt("redactions"))
            put("wire", record.toString())
        }
        db.insertOrThrow("records", null, values)
        setSyncState(id, "remote")
    }

    @Synchronized fun close() { db.close() }
    private companion object { const val CHAT_AND_MICROPHONE_SCOPE = 1 }

    private fun hash(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
}
