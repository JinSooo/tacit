package top.jinso.tacit.data

import android.content.Context
import java.util.UUID

class Preferences(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    val device: String = prefs.getString("device", null) ?: ("android-" + UUID.randomUUID()).also { prefs.edit().putString("device", it).commit() }
    fun enabled(source: String): Boolean = prefs.getBoolean("enabled.$source", false)
    /** Whether the user requested ongoing microphone capture before a restart. */
    var audioCaptureWanted: Boolean
        get() = prefs.getBoolean("audioCaptureWanted", false)
        set(value) { check(prefs.edit().putBoolean("audioCaptureWanted", value).commit()) { "无法保存录音意图" } }
    fun setEnabled(source: String, value: Boolean) { prefs.edit().putBoolean("enabled.$source", value).commit() }
    var retentionDays: Int get() = prefs.getInt("retention", 7)
        set(value) { prefs.edit().putInt("retention", value.coerceIn(1, 90)).commit() }

    /** 旧版本的暂停、聊天应用、不记录应用和采集游标都已撤下；留着的暂停标记会让人以为录音被挡住。 */
    fun dropRemovedSettings() {
        val stale = prefs.all.keys.filter { key ->
            key in setOf("paused", "pause.until", "blocked", "notification.chatApps") ||
                key.startsWith("cursor.") || key.startsWith("status.") || key.startsWith("since.") || key.endsWith(".android.usage") || key.endsWith(".android.notification")
        }
        if (stale.isNotEmpty()) prefs.edit().apply { stale.forEach(::remove) }.apply()
    }
}
