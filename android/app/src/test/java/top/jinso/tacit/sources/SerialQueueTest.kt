package top.jinso.tacit.sources

import org.junit.Assert.*
import org.junit.Test

class SerialQueueTest {
    @Test fun burstDuringSlowSaveIsProcessedOnceInOrderByOneConsumer() {
        val queue = SerialQueue<Int>(128)
        assertEquals(SerialQueue.Offer.START, queue.offer(0))
        val saved = mutableListOf(queue.poll { true }!!)
        // First save is still in flight; all subsequent callbacks must be retained.
        for (i in 1..100) assertEquals(SerialQueue.Offer.QUEUED, queue.offer(i))
        while (true) saved += queue.poll { true } ?: break
        assertEquals((0..100).toList(), saved)
        assertEquals(SerialQueue.Offer.START, queue.offer(101))
        assertEquals(101, queue.poll { true })
    }

    @Test fun fullQueueRejectsOnlyOverflowAndRetainsAcceptedOrder() {
        val queue = SerialQueue<Int>(3)
        queue.offer(1)
        queue.offer(2)
        queue.offer(3)
        assertEquals(SerialQueue.Offer.FULL, queue.offer(4))
        assertEquals(1, queue.poll { true })
        assertEquals(SerialQueue.Offer.QUEUED, queue.offer(5))
        assertEquals(listOf(2, 3, 5), generateSequence { queue.poll { true } }.toList())
    }

    private data class Pending(val generation: Long, val app: String, val read: () -> String)

    @Test fun pausedQueuedNotificationsAreDiscardedWithoutReadingTheirPayloads() {
        val queue = SerialQueue<Pending>(8)
        var paused = false
        var reads = 0
        repeat(3) { queue.offer(Pending(1, "mail") { reads++; "content" }) }
        paused = true
        val next = queue.poll { !paused }
        next?.read?.invoke()
        assertNull(next)
        assertEquals(0, reads)
        paused = false
        assertNull(queue.poll { !paused })
        assertEquals(SerialQueue.Offer.START, queue.offer(Pending(2, "mail") { reads++; "new" }))
        assertEquals("new", queue.poll { !paused }!!.read())
        assertEquals(1, reads)
    }

    @Test fun pauseThenResumeAndBlacklistChangesRejectStaleWorkBeforeExtraction() {
        val queue = SerialQueue<Pending>(8)
        var reads = 0
        queue.offer(Pending(1, "mail") { error("Old generation must not be read after resume") })
        queue.offer(Pending(2, "blocked") { error("Blacklisted payload must not be read") })
        queue.offer(Pending(2, "mail") { reads++; "current" })
        val accepted = queue.poll { it.generation == 2L && it.app != "blocked" }
        assertEquals("current", accepted!!.read())
        assertNull(queue.poll { true })
        assertEquals(1, reads)
    }

    @Test fun clearingWhileSavingDoesNotCreateASecondConsumer() {
        val queue = SerialQueue<Int>(8)
        queue.offer(1)
        assertEquals(1, queue.poll { true })
        queue.offer(2)
        queue.clear()
        assertEquals(SerialQueue.Offer.QUEUED, queue.offer(3))
        assertEquals(3, queue.poll { true })
        assertNull(queue.poll { true })
        assertEquals(SerialQueue.Offer.START, queue.offer(4))
    }
}
