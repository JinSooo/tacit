package top.jinso.tacit.ui

/** SettingsPage accepts these routes and the microphone page (Sources.AUDIO). */
internal object SettingsRoutes {
    const val MAC = "settings.mac"
    const val SPEECH = "settings.speech"
    const val RETENTION = "settings.retention"
    const val BACKGROUND = "settings.background"

    fun title(route: String?): String? = when (route) {
        MAC -> "连接 Mac"
        SPEECH -> "语音转写"
        RETENTION -> "录音保留"
        BACKGROUND -> "后台运行"
        else -> null
    }
}
