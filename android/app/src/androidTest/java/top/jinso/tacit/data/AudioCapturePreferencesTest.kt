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
    @Test fun captureIntentPersistsIndependentlyOfProcessingAndPause() {
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
            prefs.setPause(true, 0)
            prefs = Preferences(context)
            assertTrue(prefs.audioCaptureWanted)
            assertTrue(prefs.paused)
            prefs.setPause(false, 0)
            assertTrue(Preferences(context).audioCaptureWanted)
            prefs.audioCaptureWanted = false
            prefs = Preferences(context)
            assertFalse(prefs.audioCaptureWanted)
            assertTrue(prefs.enabled("android.audio"))
        } finally { base.deleteSharedPreferences(name) }
    }
}
