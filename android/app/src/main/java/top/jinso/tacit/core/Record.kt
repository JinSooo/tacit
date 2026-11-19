package top.jinso.tacit.core

import java.security.SecureRandom
import java.time.Instant

data class Draft(
    val source: String, val title: String, val body: String,
    val start: Long = System.currentTimeMillis(), val end: Long? = null,
    val app: String? = null, val sourceRef: String? = null,
    val method: String = "api", val private: Boolean = false,
    val corrects: String? = null,
)
data class HistoryRecord(
    val id: String, val source: String, val title: String, val body: String,
    val start: Long, val end: Long?, val app: String?, val sensitivity: String,
    val corrects: String?, val redactions: Int,
)
object Ids {
    private val random = SecureRandom()
    private const val alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private var last = -1L
    private val tail = IntArray(16)
    @Synchronized fun next(): String {
        val now = maxOf(System.currentTimeMillis(), last)
        if (now == last) {
            var i = 15
            while (i >= 0 && tail[i] == 31) { tail[i] = 0; i-- }
            check(i >= 0) { "ID exhausted" }; tail[i]++
        } else { for (i in tail.indices) tail[i] = random.nextInt(32); tail[0] = tail[0] and 15 }
        last = now
        var time = now; val head = CharArray(10)
        for (i in 9 downTo 0) { head[i] = alphabet[(time and 31).toInt()]; time = time ushr 5 }
        return String(head) + tail.joinToString("") { alphabet[it].toString() }
    }
}
fun iso(time: Long): String = Instant.ofEpochMilli(time).toString()
