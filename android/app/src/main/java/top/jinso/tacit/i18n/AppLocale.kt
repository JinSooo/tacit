package top.jinso.tacit.i18n

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import androidx.core.content.edit
import top.jinso.tacit.data.Preferences
import java.io.File
import java.util.Locale

internal object AppLocale {
    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences(Preferences.FILE, Context.MODE_PRIVATE)
        val initialized = prefs.getBoolean("locale_initialized", false)
        val migrateLegacyPin = Build.VERSION.SDK_INT >= 33 && prefs.getString("pinned_language", null) == "zh"
        if (initialized && !migrateLegacyPin) return
        val existing = prefs.all.isNotEmpty() || listOf("history.db", "vault.key", "vault.key.bak")
            .any { File(context.noBackupFilesDir, it).exists() }
        var legacyPin = false
        if (Build.VERSION.SDK_INT >= 33) {
            val manager = context.getSystemService(LocaleManager::class.java)
            if (shouldPinChinese(initialized, existing, manager.applicationLocales.toLanguageTags(), migrateLegacyPin)) {
                manager.applicationLocales = LocaleList.forLanguageTags("zh-Hans")
            }
        } else {
            legacyPin = shouldPinChinese(false, existing, "")
        }
        // Record the migration before the rest of startup creates installation data.
        prefs.edit(commit = true) {
            if (legacyPin) putString("pinned_language", "zh")
            if (migrateLegacyPin) remove("pinned_language")
            putBoolean("locale_initialized", true)
        }
    }

    fun wrapLegacy(context: Context): Context {
        if (Build.VERSION.SDK_INT >= 33) return context
        val prefs = context.getSharedPreferences(Preferences.FILE, Context.MODE_PRIVATE)
        return if (prefs.getString("pinned_language", null) == "zh") {
            context.createConfigurationContext(Configuration().apply { setLocale(Locale.SIMPLIFIED_CHINESE) })
        } else context
    }

    fun locale(context: Context): Locale {
        if (Build.VERSION.SDK_INT >= 33) {
            val manager = context.getSystemService(LocaleManager::class.java)
            return manager.applicationLocales[0] ?: manager.systemLocales[0] ?: Locale.ENGLISH
        }
        val pinned = context.getSharedPreferences(Preferences.FILE, Context.MODE_PRIVATE).getString("pinned_language", null)
        return if (pinned == "zh") Locale.SIMPLIFIED_CHINESE else context.resources.configuration.locales[0]
    }

    fun language(context: Context): AppLang = AppLang.resolve(locale(context))

    fun localizedContext(context: Context, lang: AppLang = language(context)): Context {
        val locale = when (lang) {
            AppLang.ZH -> Locale.SIMPLIFIED_CHINESE
            AppLang.EN -> Locale.ENGLISH
        }
        return context.createConfigurationContext(Configuration().apply { setLocale(locale) })
    }

    fun strings(context: Context, lang: AppLang = language(context)): UiStrings {
        val resources = localizedContext(context, lang).resources
        return object : UiStrings {
            override fun text(id: Int, vararg args: Any): String =
                if (args.isEmpty()) resources.getString(id) else resources.getString(id, *args)

            override fun quantity(id: Int, count: Int, vararg args: Any): String =
                resources.getQuantityString(id, count, *args)
        }
    }
}
