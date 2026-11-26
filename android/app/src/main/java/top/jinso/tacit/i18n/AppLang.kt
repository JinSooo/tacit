package top.jinso.tacit.i18n

import java.util.Locale

internal enum class AppLang(val code: String) {
    ZH("zh"), EN("en");

    companion object {
        fun resolve(locale: Locale) = if (locale.language == "zh") ZH else EN
        fun fromHub(value: String?) = entries.firstOrNull { it.code == value }
    }
}

internal fun shouldPinChinese(
    initialized: Boolean, existingInstall: Boolean, appLocaleTags: String, legacyChinesePin: Boolean = false,
): Boolean = appLocaleTags.isEmpty() && (legacyChinesePin || !initialized && existingInstall)
