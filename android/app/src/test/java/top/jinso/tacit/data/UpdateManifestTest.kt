package top.jinso.tacit.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UpdateManifestTest {
    private fun feed(version: String, url: String = "https://github.com/JinSooo/tacit/releases/tag/android-v$version") =
        """{"mac":{"version":"9.9.9","url":"https://example.com"},"android":{"version":"$version","url":"$url"}}"""

    @Test fun offersOnlyNewerAndroidBuilds() {
        assertEquals(AppUpdate("0.7.2", "https://github.com/JinSooo/tacit/releases/tag/android-v0.7.2"), UpdateManifest.newer("0.7.1", feed("0.7.2")))
        assertEquals("0.10.0", UpdateManifest.newer("0.9.9", feed("0.10.0"))?.version)
        assertNull(UpdateManifest.newer("0.7.1", feed("0.7.1")))
        assertNull(UpdateManifest.newer("0.7.1", feed("0.7")))
        assertNull(UpdateManifest.newer("0.8.0", feed("0.7.9")))
    }

    @Test fun ignoresMalformedFeedsAndDevBuilds() {
        assertNull(UpdateManifest.newer("0.7.1", """{"mac":{"version":"9.9.9","url":"https://example.com"}}"""))
        assertNull(UpdateManifest.newer("0.7.1", feed("0.8.0", url = "http://example.com")))
        assertNull(UpdateManifest.newer("0.7.1", feed("0.8.0-beta")))
        assertNull(UpdateManifest.newer("0.7.1-dev", feed("0.8.0")))
        assertNull(UpdateManifest.newer(null, feed("0.8.0")))
        assertNull(UpdateManifest.newer("0.7.1", "not json"))
    }
}
