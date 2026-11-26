package top.jinso.tacit.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI

/** The newest Android build listed in the website's `latest.json`. */
data class AppUpdate(val version: String, val page: String)

object UpdateManifest {
    const val URL = "https://tacit.jinso.top/latest.json"

    /** Accepts only `{"android":{"version":"x.y.z","url":"https://…"}}` newer than [current]; anything else means no update. */
    fun newer(current: String?, body: String): AppUpdate? {
        val parts = current?.let(::components) ?: return null
        val android = runCatching { JSONObject(body).getJSONObject("android") }.getOrNull() ?: return null
        val version = android.optString("version")
        val url = android.optString("url")
        val latest = components(version) ?: return null
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.host.isNullOrEmpty()) return null
        val order = latest.zip(parts).firstOrNull { (a, b) -> a != b }?.let { (a, b) -> a.compareTo(b) } ?: 0
        return if (order > 0) AppUpdate(version, url) else null
    }

    /** `0.7.1` → [0, 7, 1, 0]; non-numeric versions (dev builds) return null. */
    internal fun components(version: String): List<Int>? {
        val pieces = version.split(".")
        if (pieces.size !in 1..4) return null
        val numbers = pieces.map { piece ->
            if (piece.isEmpty() || !piece.all { it in '0'..'9' }) return null
            piece.toIntOrNull() ?: return null
        }
        return numbers + List(4 - numbers.size) { 0 }
    }
}

/**
 * Reads `latest.json` at most once a day while the app is open; a newer Android build shows one line on the
 * timeline. The request carries no cookies and no device details, and failures stay quiet until the next try.
 */
class UpdateCheck(context: Context, private val current: String) {
    enum class Manual { CHECKING, UP_TO_DATE, FAILED }
    data class State(val latest: AppUpdate? = null, val skipped: String? = null, val manual: Manual? = null) {
        /** What the timeline offers: the newest build unless the user skipped that version. */
        val available: AppUpdate? get() = latest?.takeIf { it.version != skipped }
    }

    private val prefs = context.getSharedPreferences("update", Context.MODE_PRIVATE)
    private val mutable = MutableStateFlow(State(skipped = prefs.getString(SKIPPED, null)))
    val state: StateFlow<State> = mutable.asStateFlow()

    /** Called whenever the timeline opens. */
    suspend fun checkIfDue() {
        prefs.getString(BODY, null)?.let(::apply)
        if (System.currentTimeMillis() - prefs.getLong(CHECKED_AT, 0) >= DAY_MS) fetch()
    }

    /** The settings button: check now regardless of the last check and keep the result on that line. */
    suspend fun checkNow() {
        if (mutable.value.manual == Manual.CHECKING) return
        mutable.update { it.copy(manual = Manual.CHECKING) }
        val ok = fetch()
        mutable.update { it.copy(manual = if (!ok) Manual.FAILED else if (it.latest == null) Manual.UP_TO_DATE else null) }
    }

    fun skip() {
        val version = mutable.value.latest?.version ?: return
        prefs.edit().putString(SKIPPED, version).apply()
        mutable.update { it.copy(skipped = version) }
    }

    private suspend fun fetch(): Boolean {
        val body = withContext(Dispatchers.IO) {
            runCatching {
                val connection = URI(UpdateManifest.URL).toURL().openConnection() as HttpURLConnection
                try {
                    connection.useCaches = false
                    connection.connectTimeout = 15_000
                    connection.readTimeout = 15_000
                    connection.setRequestProperty("User-Agent", "Tacit")
                    if (connection.responseCode != 200) return@runCatching null
                    val bytes = connection.inputStream.use { input ->
                        val out = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(4096)
                        while (out.size() <= LIMIT) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            out.write(buffer, 0, n)
                        }
                        out.toByteArray()
                    }
                    if (bytes.size > LIMIT) null else String(bytes, Charsets.UTF_8)
                } finally { connection.disconnect() }
            }.getOrNull()
        } ?: return false
        prefs.edit().putLong(CHECKED_AT, System.currentTimeMillis()).putString(BODY, body).apply()
        apply(body)
        return true
    }

    private fun apply(body: String) {
        val latest = UpdateManifest.newer(current, body)
        mutable.update { it.copy(latest = latest) }
    }

    private companion object {
        const val SKIPPED = "skippedVersion"
        const val CHECKED_AT = "checkedAt"
        const val BODY = "body"
        const val LIMIT = 16 * 1024
        const val DAY_MS = 24 * 3600 * 1000L
    }
}
