package top.jinso.tacit.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.security.KeyStore
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class TimelineItem(
    val id: String, val start: Instant, val title: String, val description: String,
    val sources: List<String>, val recordIds: Set<String>,
    /** 还没被模型整理的草稿段，列表上用空心点，和 Mac 一致。 */
    val draft: Boolean = false,
) {
    fun timeLabel(zone: ZoneId = ZoneId.systemDefault()): String = clockFormat.format(start.atZone(zone))
}

internal data class TimelineDay(
    val overview: String?, val items: List<TimelineItem>, val drafts: List<TimelineItem>,
) {
    fun entries(today: Boolean): List<TimelineItem> =
        (items + if (today) drafts else emptyList()).distinctBy { it.id }
}

internal data class TimelineSnapshot(
    val days: Map<LocalDate, TimelineDay> = emptyMap(),
    val invalidation: Long = 0,
    val lastSync: Long = 0,
    val refreshFailedAt: Long? = null,
) {
    fun staleTime(day: LocalDate, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String? {
        if (refreshFailedAt == null || day != now.atZone(zone).toLocalDate() || day !in days ||
            lastSync == 0L || now.toEpochMilli() - lastSync <= 60 * 60_000L) return null
        val synced = Instant.ofEpochMilli(lastSync).atZone(zone)
        return if (synced.toLocalDate() == day) clockFormat.format(synced)
        else DateTimeFormatter.ofPattern("M 月 d 日 HH:mm").format(synced)
    }
}
internal data class ProjectionCursor(val epoch: Long = 0, val seq: Long = 0) {
    fun pullBody() = JSONObject().put("cursor", seq).apply {
        if (epoch > 0) put("epoch", epoch)
        if (seq == 0L) put("window_days", TIMELINE_DAYS)
    }

    fun ackBody() = JSONObject().put("epoch", epoch).put("cursor", seq)
}

private const val TIMELINE_DAYS = 30
private val clockFormat = DateTimeFormatter.ofPattern("HH:mm")
internal fun JSONArray.objects() = (0 until length()).map(::getJSONObject)

private fun JSONObject.items(key: String, draft: Boolean = false): List<TimelineItem> = optJSONArray(key)?.objects().orEmpty().map { item ->
    TimelineItem(
        item.getString("id"), OffsetDateTime.parse(item.getString("t_start")).toInstant(),
        item.getString("title"), (item.optionalString("description") ?: item.optionalString("excerpt")).orEmpty(),
        item.optJSONArray("sources")?.strings().orEmpty(), item.optJSONArray("record_ids")?.strings().orEmpty().toSet(), draft,
    )
}

private class CachedDay(val data: JSONObject) {
    private val detail = data.optJSONObject("detail")
    val day = TimelineDay(detail?.optionalString("summary") ?: data.optionalString("brief"),
        detail?.items("items").orEmpty(), data.items("drafts", draft = true))
    val references = (day.items + day.drafts).flatMap { it.recordIds }.toSet() +
        detail?.optJSONArray("omitted_record_ids")?.strings().orEmpty()

    fun withdraw(ids: Set<String>): CachedDay {
        if (references.none { it in ids }) return this
        fun keep(items: JSONArray?) = JSONArray(items?.objects().orEmpty().filter { item ->
            item.optJSONArray("record_ids")?.strings().orEmpty().none { it in ids }
        })
        val updated = JSONObject(data.toString()).apply {
            remove("brief")
            put("drafts", keep(optJSONArray("drafts")))
            optJSONObject("detail")?.apply {
                remove("summary")
                put("items", keep(optJSONArray("items")))
                put("omitted_record_ids", JSONArray(optJSONArray("omitted_record_ids")?.strings().orEmpty() - ids))
            }
        }
        return CachedDay(updated)
    }
}

internal interface TimelineDisk {
    fun read(owner: String): JSONObject?
    fun write(owner: String, state: JSONObject)
    fun clear()
}

/** One atomic encrypted snapshot commits the day edits and cursor together before the hub is acknowledged. */
internal class EncryptedTimelineDisk(context: Context) : TimelineDisk {
    private val file = AtomicFile(File(context.noBackupFilesDir, "timeline.cache"))

    override fun read(owner: String): JSONObject? {
        val data = try { file.readFully() } catch (_: FileNotFoundException) { return null }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        cipher.updateAAD(owner.toByteArray())
        return JSONObject(cipher.doFinal(data, 12, data.size - 12).toString(Charsets.UTF_8))
    }

    override fun write(owner: String, state: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(owner.toByteArray())
        val data = cipher.iv + cipher.doFinal(state.toString().toByteArray())
        val output = file.startWrite()
        try {
            output.write(data)
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    override fun clear() { file.delete() }

    private fun key(create: Boolean): SecretKey {
        val alias = "tacit.timeline.v1"
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
            generateKey()
        }
    }
}

/** Local deletes can withdraw cached text while the sync coordinator is waiting for the network. */
internal class TimelineCache(
    private val disk: TimelineDisk,
    private val isDeleted: (String) -> Boolean = { false },
    private val today: () -> LocalDate = LocalDate::now,
) {
    private var owner: String? = null
    private var bound = false
    private var lastSync = 0L
    private var refreshFailedAt: Long? = null
    private var days = emptyMap<LocalDate, CachedDay>()
    var cursor = ProjectionCursor()
        private set
    private val mutable = MutableStateFlow(TimelineSnapshot())
    val snapshots = mutable.asStateFlow()

    @Synchronized fun bind(device: String?) {
        if (bound && owner == device) {
            prune()
            return
        }
        owner = device
        bound = true
        try {
            val state = device?.let(disk::read)
            if (state == null) {
                clear()
                return
            }
            cursor = ProjectionCursor(state.integer("epoch"), state.integer("cursor"))
            lastSync = state.optLong("lastSync")
            refreshFailedAt = null
            val stored = state.getJSONObject("days")
            days = stored.keys().asSequence().associate { LocalDate.parse(it) to CachedDay(stored.getJSONObject(it)) }
            withdrawRecords(days.values.flatMap { it.references }.filter(isDeleted).toSet())
            prune()
            publish(invalidate = true)
        } catch (_: Exception) {
            clear()
        }
    }

    @Synchronized fun clear() {
        val invalidated = days.isNotEmpty() || cursor != ProjectionCursor()
        days = emptyMap()
        lastSync = 0L
        refreshFailedAt = null
        cursor = ProjectionCursor()
        publish(invalidated)
        disk.clear()
    }

    @Synchronized fun reset(epoch: Long) {
        clear()
        cursor = ProjectionCursor(epoch)
    }

    @Synchronized fun apply(epoch: Long, seq: Long, changes: JSONArray, syncedAt: Long? = null) {
        val changedEpoch = cursor.epoch != 0L && epoch != cursor.epoch
        val previous = if (changedEpoch) ProjectionCursor() else cursor
        val next = if (changedEpoch) mutableMapOf() else days.toMutableMap()
        var invalidate = changedEpoch
        for (change in changes.objects()) {
            val changeSeq = change.integer("seq")
            if (changeSeq <= previous.seq) continue
            val id = change.getString("id")
            when (change.getString("kind")) {
                "day" -> {
                    val day = LocalDate.parse(id)
                    if (change.getString("op") == "delete") {
                        next.remove(day)
                        invalidate = true
                    } else if (day >= oldest()) {
                        val incoming = CachedDay(change.getJSONObject("data"))
                        next[day] = incoming.withdraw(incoming.references.filter(isDeleted).toSet())
                    }
                }
                "record_gone" -> {
                    next.entries.removeAll { id in it.value.references }
                    invalidate = true
                }
            }
        }
        if (seq >= previous.seq) commit(next, ProjectionCursor(epoch, seq), invalidate, syncedAt)
    }

    @Synchronized fun invalidate(epoch: Long, toSeq: Long, items: JSONArray) {
        if (cursor.epoch != 0L && cursor.epoch != epoch) {
            reset(epoch)
            return
        }
        if (cursor.epoch == epoch && toSeq <= cursor.seq) return
        val next = days.toMutableMap()
        for (item in items.objects()) {
            val id = item.getString("id")
            when (item.getString("kind")) {
                "day" -> next.remove(LocalDate.parse(id))
                "record_gone" -> next.entries.removeAll { id in it.value.references }
            }
        }
        commit(next, cursor, invalidate = true)
    }

    @Synchronized fun withdrawRecords(ids: Set<String>) {
        if (ids.isEmpty()) return
        val next = days.mapValues { (_, value) -> value.withdraw(ids) }
        commit(next, cursor, invalidate = next != days)
    }

    @Synchronized fun refreshFailed() {
        refreshFailedAt = System.currentTimeMillis()
        publish(invalidate = false)
    }

    private fun oldest() = today().minusDays(TIMELINE_DAYS - 1L)

    private fun prune() {
        if (days.keys.any { it < oldest() }) commit(days.filterKeys { it >= oldest() }, cursor)
    }

    private fun commit(
        next: Map<LocalDate, CachedDay>, position: ProjectionCursor,
        invalidate: Boolean = false, syncedAt: Long? = null,
    ) {
        val timestamp = syncedAt ?: if (invalidate && position.epoch != cursor.epoch) 0 else lastSync
        if (next != days || position != cursor || timestamp != lastSync) {
            val data = JSONObject()
            next.forEach { (day, value) -> data.put(day.toString(), value.data) }
            try {
                disk.write(checkNotNull(owner), JSONObject().put("epoch", position.epoch)
                    .put("cursor", position.seq).put("days", data).put("lastSync", timestamp))
            } catch (error: Exception) {
                clear()
                throw error
            }
            cursor = position
            days = next
            lastSync = timestamp
        }
        if (syncedAt != null) refreshFailedAt = null
        publish(invalidate)
    }

    private fun publish(invalidate: Boolean) {
        mutable.value = TimelineSnapshot(days.mapValues { it.value.day },
            mutable.value.invalidation + if (invalidate) 1 else 0, lastSync, refreshFailedAt)
    }
}
