package top.jinso.tacit.ui

import android.text.format.DateFormat
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.AppLocale
import top.jinso.tacit.i18n.UiStrings

private val LocalUiStrings = compositionLocalOf<UiStrings> { error("UiStrings not provided") }
private val LocalUiFormat = compositionLocalOf<UiFormat> { error("UiFormat not provided") }

@Composable
internal fun ProvideUiLocalization(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val locale = AppLocale.locale(context)
    val lang = AppLang.resolve(locale)
    val use24Hour = DateFormat.is24HourFormat(context)
    val strings = remember(context, configuration, lang) { AppLocale.strings(context, lang) }
    val format = remember(strings, lang, use24Hour) { UiFormat(strings, lang, use24Hour) }
    CompositionLocalProvider(LocalUiStrings provides strings, LocalUiFormat provides format, content = content)
}

@Composable internal fun uiStrings() = LocalUiStrings.current

@Composable internal fun uiFormat() = LocalUiFormat.current
