package top.jinso.tacit.sources

/** Bounded pending work with one drain owner. Payloads remain opaque until accepted by poll. */
internal class SerialQueue<T : Any>(private val capacity: Int) {
    enum class Offer { START, QUEUED, FULL }
    private val pending = java.util.ArrayDeque<T>()
    private var draining = false

    init { require(capacity > 0) }

    @Synchronized fun offer(item: T): Offer {
        if (pending.size >= capacity) return Offer.FULL
        pending.addLast(item)
        if (draining) return Offer.QUEUED
        draining = true
        return Offer.START
    }

    /** Revalidate queued metadata before the consumer can extract any content. */
    @Synchronized fun poll(allowed: (T) -> Boolean): T? {
        while (pending.isNotEmpty()) {
            val item = pending.removeFirst()
            if (allowed(item)) return item
        }
        draining = false
        return null
    }

    // An in-flight consumer still owns the drain, even when pending work is cleared.
    @Synchronized fun clear() { pending.clear() }
}
