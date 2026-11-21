package top.jinso.tacit.ui

/** SettingsPage accepts these routes and source IDs. */
internal object SettingsRoutes {
    const val MAC = "settings.mac"
    const val SOURCES = "settings.sources"
    const val SPEECH = "settings.speech"
    const val PRIVACY = "settings.privacy"
    const val RETENTION = "settings.retention"
    const val BACKGROUND = "settings.background"
    const val SHORTCUT = "settings.shortcut"
    const val EXCLUSIONS = "settings.exclusions"

    fun title(route: String?): String? = when (route) {
        MAC -> "连接 Mac"
        SOURCES -> "数据源"
        SPEECH -> "语音转写"
        RETENTION -> "录音保留"
        BACKGROUND -> "后台运行"
        SHORTCUT -> "桌面快捷补写"
        EXCLUSIONS -> "不记录的应用"
        else -> null
    }
}
