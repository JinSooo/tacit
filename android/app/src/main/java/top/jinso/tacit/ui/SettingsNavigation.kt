package top.jinso.tacit.ui

import top.jinso.tacit.R
import top.jinso.tacit.i18n.UiStrings

/** SettingsPage accepts these routes and the microphone page (Sources.AUDIO). */
internal object SettingsRoutes {
    const val MAC = "settings.mac"
    const val SPEECH = "settings.speech"
    const val SUMMARY = "settings.summary"
    const val RETENTION = "settings.retention"
    const val BACKGROUND = "settings.background"

    fun title(route: String?, strings: UiStrings): String? = when (route) {
        MAC -> strings.text(R.string.connect_mac)
        SPEECH -> strings.text(R.string.speech_transcription)
        SUMMARY -> strings.text(R.string.ai_summaries)
        RETENTION -> strings.text(R.string.audio_retention)
        BACKGROUND -> strings.text(R.string.background_operation)
        else -> null
    }
}
