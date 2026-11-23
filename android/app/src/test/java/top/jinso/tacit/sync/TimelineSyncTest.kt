package top.jinso.tacit.sync

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.Instant
import java.time.ZoneId

class TimelineSyncTest {
    private val today = LocalDate.parse("2026-11-24")
    private val disk = MemoryDisk()
    private val cache = TimelineCache(disk) { today }.apply { bind("test-hub:test-phone") }
    private val sync = TimelineSync(cache)

    @Test fun appliesUpsertDeleteRecordGoneAndReset() {
        val yesterday = today.minusDays(1)
        cache.apply(1, 2, JSONArray(listOf(day(today, 1), day(yesterday, 2))))
        assertEquals(setOf(today, yesterday), cache.snapshots.value.days.keys)
        assertEquals("梳理虚构展览", cache.snapshots.value.days[today]?.items?.single()?.title)

        cache.apply(1, 3, JSONArray(listOf(change(3, "day", yesterday.toString()))))
        assertEquals(setOf(today), cache.snapshots.value.days.keys)
        cache.apply(1, 4, JSONArray(listOf(change(4, "record_gone", "fixture-record"))))
        assertTrue(cache.snapshots.value.days.isEmpty())
        assertEquals(4L, disk.state?.getLong("cursor"))

        cache.apply(1, 5, JSONArray(listOf(day(today, 5))))
        assertTrue(sync.push(JSONObject().put("kind", "projection.reset").put("epoch", 2), view = false))
        assertTrue(cache.snapshots.value.days.isEmpty())
        assertNull(disk.state)
        assertEquals(ProjectionCursor(2, 0), cache.cursor)
    }

    @Test fun newEpochReplacesOldSnapshotEvenWhenSequenceGoesBackwards() {
        cache.apply(1, 24, JSONArray(listOf(day(today, 24))))
        val recent = today.minusDays(29)
        cache.apply(2, 2, JSONArray(listOf(day(today.minusDays(30), 1), day(recent, 2))))

        val restarted = TimelineCache(disk) { today }.apply { bind("test-hub:test-phone") }
        assertEquals(setOf(recent), restarted.snapshots.value.days.keys)
        assertEquals(ProjectionCursor(2, 2), restarted.cursor)
        restarted.bind("other-hub:other-phone")
        assertTrue(restarted.snapshots.value.days.isEmpty())
    }

    @Test fun collectAndUnknownRoleNeverPullAndClearExistingCache() = runBlocking {
        for (role in listOf("collect", null)) {
            cache.apply(1, 1, JSONArray(listOf(day(today, 1))))
            sync.pull(role) { _, _ -> error("collect must not pull") }
            assertNull(disk.state)
            assertTrue(cache.snapshots.value.days.isEmpty())
        }
    }

    @Test fun removedDeviceClearsDiskAndView() = runBlocking {
        cache.apply(1, 1, JSONArray(listOf(day(today, 1))))
        val hub = DeviceEnvelope.generate()
        val client = DeviceClient(DeviceEnvelope.public(hub).base64url(), DeviceEnvelope.generate(),
            { DeviceHttpReply(401) }, "android-aebagbaf")
        try {
            sync.pull("view", client::send)
            fail("Expected removal")
        } catch (_: DeviceRemoved) { }
        assertNull(disk.state)
        assertTrue(cache.snapshots.value.days.isEmpty())
    }

    @Test fun resetColdPullUsesThirtyDaysAndAcknowledgesOnlyCommittedProgress() = runBlocking {
        cache.apply(1, 9, JSONArray(listOf(day(today, 9))))
        val requests = mutableListOf<String>()
        sync.pull("view") { op, body ->
            requests += op
            when (requests.size) {
                1 -> JSONObject().put("epoch", 2).put("reset", true).put("more", true)
                2 -> {
                    assertNull(disk.state)
                    assertEquals(30, body.getInt("window_days"))
                    assertEquals(0, body.getInt("cursor"))
                    JSONObject().put("epoch", 2).put("reset", false).put("more", false).put("cursor", 1)
                        .put("changes", JSONArray(listOf(day(today, 1))))
                }
                else -> {
                    assertEquals(disk.state?.getLong("cursor"), body.getLong("cursor"))
                    JSONObject().put("ok", true)
                }
            }
        }
        assertEquals(listOf("projection.pull", "projection.pull", "projection.ack"), requests)
    }

    @Test fun urgentRelayInvalidationRemovesDataWithoutSkippingThePullCursor() {
        cache.apply(1, 1, JSONArray(listOf(day(today, 1))))
        val invalidation = JSONObject().put("kind", "projection.invalidate").put("epoch", 1).put("to_seq", 2)
            .put("items", JSONArray(listOf(change(2, "record_gone", "fixture-record"))))
        assertTrue(sync.push(invalidation, view = false))
        assertEquals(ProjectionCursor(1, 1), cache.cursor)
        assertTrue(cache.snapshots.value.days.isEmpty())
        assertEquals(0, disk.state?.getJSONObject("days")?.length())
    }

    @Test fun relayDeltaCannotAdvanceAcrossGapAndAppliesOnlyWithViewPermission() {
        cache.apply(1, 1, JSONArray(listOf(day(today, 1))))
        val delta = JSONObject().put("kind", "projection.delta").put("epoch", 1)
            .put("from_seq", 2).put("to_seq", 3)
            .put("changes", JSONArray(listOf(change(3, "day", today.toString()))))
        assertFalse(sync.push(delta, view = false))
        assertTrue(sync.push(delta, view = true))
        assertEquals(1L, cache.cursor.seq)
        assertTrue(sync.push(delta.put("from_seq", 1), view = true))
        assertEquals(3L, cache.cursor.seq)
        assertTrue(cache.snapshots.value.days.isEmpty())
    }

    // 回归（2026-11-24 审查第 2 条）
    @Test fun withdrawingLocalDeleteKeepsOtherSegmentsAndCannotBeUndoneByAnOldReply() {
        val unrelated = today.minusDays(1)
        val original = day(today, 1)
        val data = original.getJSONObject("data")
        val items = data.getJSONObject("detail").getJSONArray("items")
        items.put(JSONObject(items.getJSONObject(0).toString()).put("id", "unaffected")
            .put("record_ids", JSONArray(listOf("other-record"))))
        data.put("drafts", JSONArray(listOf(JSONObject(items.getJSONObject(0).toString()).put("id", "draft"))))
        val otherDay = day(unrelated, 2)
        otherDay.getJSONObject("data").getJSONObject("detail").getJSONArray("items").getJSONObject(0)
            .put("record_ids", JSONArray(listOf("other-day-record")))
        val gone = mutableSetOf<String>()
        val localCache = TimelineCache(disk, isDeleted = { it in gone }) { today }.apply {
            bind("test-hub:test-phone")
            apply(1, 2, JSONArray(listOf(original, otherDay)))
        }
        gone += "fixture-record"
        localCache.withdrawRecords(gone)
        val affected = localCache.snapshots.value.days.getValue(today)
        assertEquals(listOf("unaffected"), affected.items.map { it.id })
        assertTrue(affected.drafts.isEmpty())
        assertNull(affected.overview)
        assertEquals("安排展览", localCache.snapshots.value.days[unrelated]?.overview)
        assertEquals(ProjectionCursor(1, 2), localCache.cursor)
        assertEquals(1, localCache.snapshots.value.invalidation)
        val restarted = TimelineCache(disk, isDeleted = { it in gone }) { today }.apply {
            bind("test-hub:test-phone")
            apply(1, 3, JSONArray(listOf(original.put("seq", 3))))
        }
        assertEquals(affected, restarted.snapshots.value.days[today])
    }

    // 回归（2026-11-24 审查第 4 条）
    @Test fun cachedOffsetIsConvertedToPhoneTimeAndNullDescriptionsAreEmpty() {
        val change = day(today, 1)
        change.getJSONObject("data").getJSONObject("detail").getJSONArray("items").getJSONObject(0)
            .put("t_start", "2026-11-23T20:43:41+08:00")
            .put("description", JSONObject.NULL).put("excerpt", JSONObject.NULL)
        cache.apply(1, 1, JSONArray(listOf(change)))
        val item = cache.snapshots.value.days.getValue(today).items.single()
        assertEquals(Instant.parse("2026-11-23T12:43:41Z"), item.start)
        assertEquals("07:43", item.timeLabel(ZoneId.of("America/New_York")))
        assertEquals("", item.description)
    }

    // 回归（2026-11-24 审查第 7 条）
    @Test fun pullAndAckConflictsRetryFromCommittedCursorWithoutWipingOtherDays() = runBlocking {
        cache.apply(1, 1, JSONArray(listOf(day(today, 1))))
        val requested = mutableListOf<Pair<String, Long>>()
        sync.pull("view") { op, body ->
            requested += op to body.getLong("cursor")
            assertTrue(today in cache.snapshots.value.days)
            when (requested.size) {
                1, 3 -> throw DeviceStatus(409, op)
                2, 4 -> JSONObject().put("epoch", 1).put("reset", false).put("more", false)
                    .put("cursor", 2).put("changes", JSONArray())
                else -> JSONObject().put("ok", true)
            }
        }
        assertEquals(listOf("projection.pull" to 1L, "projection.pull" to 1L, "projection.ack" to 2L,
            "projection.pull" to 2L, "projection.ack" to 2L), requested)
        var calls = 0
        try {
            sync.pull("view") { op, _ -> calls++; throw DeviceStatus(409, op) }
            fail("Expected a bounded conflict retry")
        } catch (error: DeviceStatus) {
            assertEquals(409, error.status)
        }
        assertEquals(4, calls)
        assertTrue(today in cache.snapshots.value.days)
    }

    private fun day(date: LocalDate, seq: Long): JSONObject {
        val item = JSONObject().put("id", "fixture-item").put("title", "梳理虚构展览")
            .put("description", "确认合成示例的顺序").put("t_start", "${date}T14:30:00+08:00")
            .put("sources", JSONArray(listOf("mac.wechat"))).put("record_ids", JSONArray(listOf("fixture-record")))
        val data = JSONObject().put("detail", JSONObject().put("summary", "安排展览").put("items", JSONArray(listOf(item))))
        return change(seq, "day", date.toString()).put("op", "upsert").put("data", data)
    }

    private fun change(seq: Long, kind: String, id: String) =
        JSONObject().put("kind", kind).put("id", id).put("seq", seq).put("op", "delete")

    private class MemoryDisk : TimelineDisk {
        var state: JSONObject? = null
        private var currentOwner: String? = null
        override fun read(owner: String): JSONObject? = state?.takeIf { currentOwner == owner }
        override fun write(owner: String, state: JSONObject) {
            currentOwner = owner
            this.state = JSONObject(state.toString())
        }
        override fun clear() { state = null }
    }
}
