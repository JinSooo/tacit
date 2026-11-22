package top.jinso.tacit.data

import android.content.Context
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class AudioCapturePreferencesTest {
    @Test fun captureIntentPersistsIndependentlyOfProcessing() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "capture-intent-test-${UUID.randomUUID()}"
        val context = object : ContextWrapper(base) {
            override fun getSharedPreferences(ignored: String, mode: Int) = base.getSharedPreferences(name, Context.MODE_PRIVATE)
        }
        try {
            var prefs = Preferences(context)
            assertFalse(prefs.audioCaptureWanted)
            prefs.setEnabled("android.audio", true) // Import-only setup must not request a microphone.
            prefs = Preferences(context)
            assertTrue(prefs.enabled("android.audio"))
            assertFalse(prefs.audioCaptureWanted)
            prefs.audioCaptureWanted = true
            prefs = Preferences(context)
            assertTrue(prefs.audioCaptureWanted)
            prefs.audioCaptureWanted = false
            prefs = Preferences(context)
            assertFalse(prefs.audioCaptureWanted)
            assertTrue(prefs.enabled("android.audio"))
        } finally { base.deleteSharedPreferences(name) }
    }

    // 0.4.1 升级上来时若正处于暂停，旧的暂停标记没有入口能解除；升级后要清掉，录音开关不受影响。
    @Test fun upgradeDropsRemovedPauseAndCollectorSettings() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "removed-settings-test-${UUID.randomUUID()}"
        val context = object : ContextWrapper(base) {
            override fun getSharedPreferences(ignored: String, mode: Int) = base.getSharedPreferences(name, Context.MODE_PRIVATE)
        }
        try {
            val raw = context.getSharedPreferences(name, Context.MODE_PRIVATE)
            raw.edit().putBoolean("paused", true).putLong("pause.until", 0).putStringSet("blocked", setOf("a.b"))
                .putStringSet("notification.chatApps", setOf("com.tencent.mm")).putLong("cursor.android.usage", 5)
                .putBoolean("enabled.android.usage", true).putBoolean("enabled.android.notification", true)
                .putString("status.android.audio", "录音未启动").commit()
            val prefs = Preferences(context)
            prefs.setEnabled("android.audio", true)
            prefs.dropRemovedSettings()
            assertEquals(setOf("device", "enabled.android.audio"), raw.all.keys)
        } finally { base.deleteSharedPreferences(name) }
    }
}
