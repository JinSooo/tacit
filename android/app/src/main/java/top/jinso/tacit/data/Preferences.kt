package top.jinso.tacit.data

import android.content.Context
import java.util.UUID
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.sources.WECHAT_PACKAGE

class Preferences(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    val device: String = prefs.getString("device", null) ?: ("android-" + UUID.randomUUID()).also { prefs.edit().putString("device", it).commit() }
    var paused: Boolean
        get() = top.jinso.tacit.core.PausePolicy.active(prefs.getBoolean("paused", false), pauseUntil, System.currentTimeMillis())
        set(value) { setPause(value, 0) }
    val pauseUntil: Long get() = prefs.getLong("pause.until", 0)
    fun setPause(value: Boolean, until: Long) {
        prefs.edit().putBoolean("paused", value).putLong("pause.until", if (value) until else 0).commit()
    }
    fun enabled(source: String): Boolean = prefs.getBoolean("enabled.$source", false)
    /** Whether the user requested ongoing microphone capture before a pause or restart. */
    var audioCaptureWanted: Boolean
        get() = prefs.getBoolean("audioCaptureWanted", false)
        set(value) { check(prefs.edit().putBoolean("audioCaptureWanted", value).commit()) { "无法保存录音意图" } }
    fun setEnabled(source: String, value: Boolean) { prefs.edit().putBoolean("enabled.$source", value).putLong("since.$source", System.currentTimeMillis()).commit() }
    fun since(source: String): Long = prefs.getLong("since.$source", System.currentTimeMillis())
    fun cursor(key: String, default: Long = 0): Long = prefs.getLong("cursor.$key", default)
    fun setCursor(key: String, value: Long) { prefs.edit().putLong("cursor.$key", value).commit() }
    fun status(source: String): String = prefs.getString("status.$source", "尚未运行")!!
    fun setStatus(source: String, value: String) { prefs.edit().putString("status.$source", value).apply() }
    var retentionDays: Int get() = prefs.getInt("retention", 7)
        set(value) { prefs.edit().putInt("retention", value.coerceIn(1, 90)).commit() }
    var blockedApps: Set<String> get() = prefs.getStringSet("blocked", setOf("com.android.settings", "com.android.systemui", "com.miui.securitycenter", "com.android.permissioncontroller", "com.google.android.permissioncontroller", "com.android.camera", "com.miui.gallery", "com.google.android.apps.photos", "com.android.contacts", "com.android.incallui", "com.android.mms", "com.tencent.mm.plugin.wallet", "com.eg.android.AlipayGphone", "com.unionpay", "com.xiaomi.account", "com.agilebits.onepassword", "com.onepassword.android", "com.x8bit.bitwarden"))!!.toSet()
        set(value) { prefs.edit().putStringSet("blocked", value).commit() }
    var chatApps: Set<String>
        get() = prefs.getStringSet("notification.chatApps", setOf(WECHAT_PACKAGE)).orEmpty().toSet()
        internal set(value) {
            check(prefs.edit().putStringSet("notification.chatApps", value.toSet()).commit()) { "无法保存聊天应用" }
        }
    fun allowsChatNotification(packageName: String): Boolean =
        packageName in chatApps && allows(Sources.NOTIFICATION, packageName)

    fun allows(source: String, app: String? = null): Boolean = !paused && enabled(source) && (app == null || app !in blockedApps && app != "top.jinso.tacit")
}
