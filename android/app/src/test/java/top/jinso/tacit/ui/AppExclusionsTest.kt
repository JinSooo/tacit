package top.jinso.tacit.ui

import org.junit.Assert.*
import org.junit.Test

class AppExclusionsTest {
    private val hidden = setOf(
        "com.android.systemui",          // System service without a launcher entry.
        "com.old.uninstalled",           // No longer installed.
        "com.tencent.mm.plugin.wallet",  // Existing component-like exclusion.
        "com.example/.PrivateActivity",  // Keep legacy entries exactly as stored.
    )

    @Test fun selectingASearchedAppPreservesAllNonVisibleExclusions() {
        val original = hidden + "com.other.launchable"
        val updated = withAppExclusion(original, "com.example.visible", true)
        assertEquals(hidden + setOf("com.other.launchable", "com.example.visible"), updated)
        assertEquals(hidden + "com.other.launchable", original)
    }

    @Test fun deselectingAppOnlyRemovesExactPackageNotComponentsOrFilteredApps() {
        val original = hidden + setOf("com.tencent.mm", "com.other.launchable")
        val updated = withAppExclusion(original, "com.tencent.mm", false)
        assertEquals(hidden + "com.other.launchable", updated)
        assertTrue("com.tencent.mm.plugin.wallet" in updated)
    }

    @Test fun repeatedTogglesPreserveExclusionsAddedSinceListWasLoaded() {
        val loaded = hidden + "com.example.visible"
        val current = loaded + "com.new.hidden"
        val unchecked = withAppExclusion(current, "com.example.visible", false)
        val checked = withAppExclusion(unchecked, "com.example.visible", true)
        assertEquals(current, checked)
    }
}
