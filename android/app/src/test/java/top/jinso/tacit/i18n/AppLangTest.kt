package top.jinso.tacit.i18n

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class AppLangTest {
    @Test fun onlyExistingInstallsWithoutAnOverrideArePinnedOnce() {
        assertTrue(shouldPinChinese(initialized = false, existingInstall = true, appLocaleTags = ""))
        assertFalse(shouldPinChinese(initialized = false, existingInstall = false, appLocaleTags = ""))
        assertFalse(shouldPinChinese(initialized = false, existingInstall = true, appLocaleTags = "en"))
        assertFalse(shouldPinChinese(initialized = true, existingInstall = true, appLocaleTags = ""))
        assertTrue(shouldPinChinese(initialized = true, existingInstall = true, appLocaleTags = "", legacyChinesePin = true))
        assertFalse(shouldPinChinese(initialized = true, existingInstall = true, appLocaleTags = "en", legacyChinesePin = true))
    }

    @Test fun allChineseLocalesUseSimplifiedChineseAndOthersUseEnglish() {
        for (tag in listOf("zh", "zh-Hans", "zh-CN", "zh-TW", "zh-HK", "zh-Hant-TW")) {
            assertEquals(tag, AppLang.ZH, AppLang.resolve(Locale.forLanguageTag(tag)))
        }
        for (tag in listOf("en-US", "en-GB", "fr-CA", "ja-JP")) {
            assertEquals(tag, AppLang.EN, AppLang.resolve(Locale.forLanguageTag(tag)))
        }
    }

    @Test fun speechUnitsMatchEverySharedHubFixture() {
        val cases = JSONArray(fixture("scripts/fixtures/i18n/speech-units.json").readText())
        for (i in 0 until cases.length()) {
            val row = cases.getJSONObject(i)
            val text = row.getString("text")
            assertEquals(text, row.getInt("units"), speechUnits(text))
        }
    }
}
