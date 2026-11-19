package top.jinso.tacit.ui.onboarding

/** Observed facts only. Enabled means intent, never proof that a service is running. */
internal data class SourceHealth(
    val id: String,
    val name: String,
    val enabled: Boolean,
    val granted: Boolean,
    val permissionText: String,
    val status: String = "",
)

internal data class CollectionHealth(
    val paused: Boolean,
    val sources: List<SourceHealth>,
    val microphoneGranted: Boolean,
    val audioEnabled: Boolean,
    val audioCaptureWanted: Boolean,
    val audioRunning: Boolean?,
    val audioStarting: Boolean,
    val audioSilenced: Boolean,
    val notificationsEnabled: Boolean?,
    val audioChannel: ChannelAccess,
    val batteryExempt: Boolean?,
    val backgroundRestricted: Boolean?,
    val powerSave: Boolean?,
) {
    val microphoneCaptureExpected: Boolean
        get() = audioEnabled && (audioCaptureWanted || audioRunning == true || audioStarting)
}

internal enum class ChannelAccess { NOT_CREATED, ALLOWED, BLOCKED, UNKNOWN }
internal enum class RecoveryAction { SOURCE, AUDIO, NOTIFICATIONS }
internal data class RecoveryIssue(val title: String, val detail: String, val action: RecoveryAction, val source: String? = null)

internal fun recoveryIssues(health: CollectionHealth): List<RecoveryIssue> = buildList {
    // A deliberate pause must not be presented as a failure or a request to restart.
    if (health.paused) return@buildList
    health.sources.filter { it.enabled && !it.granted }.forEach {
        add(RecoveryIssue("${it.name}需要授权", "权限尚未允许或已经失效。检查后才会继续读取。", RecoveryAction.SOURCE, it.id))
    }
    if (health.microphoneCaptureExpected) {
        when {
            !health.microphoneGranted -> add(RecoveryIssue("麦克风尚未允许", "请在设置中允许麦克风，再到录音页手动开始。", RecoveryAction.SOURCE, "android.audio"))
            health.audioRunning == null -> add(RecoveryIssue("暂时无法检查录音", "请到录音页检查权限、模型和存储状态。", RecoveryAction.AUDIO))
            health.audioSilenced -> add(RecoveryIssue("录音暂时收不到声音", "检查其他应用是否占用麦克风，或系统是否关闭了麦克风访问。录音服务会等待系统恢复。", RecoveryAction.AUDIO))
            !health.audioRunning && !health.audioStarting -> add(RecoveryIssue("录音当前未运行", "暂停、重启或系统停止后，需要回到录音页手动开始。已有录音仍保留。", RecoveryAction.AUDIO))
        }
    }

    if (health.microphoneCaptureExpected &&
        (health.notificationsEnabled == false || health.audioChannel == ChannelAccess.BLOCKED)) {
        add(RecoveryIssue("运行通知未完全开启", "录音服务可能仍在运行，请检查 Tacit 的通知设置。", RecoveryAction.NOTIFICATIONS))
    }
}

internal fun audioPermissionText(health: CollectionHealth): String = when {
    !health.audioEnabled -> "尚未启用。需要时在录音页主动开始，不会随其他来源开启。"
    !health.microphoneCaptureExpected -> "还未开启麦克风采集，可在录音页开始。"
    health.microphoneGranted -> "系统权限已允许"
    else -> "系统权限尚未允许"
}

internal fun audioReadyText(health: CollectionHealth): String = when {
    health.paused -> "已暂停"
    !health.audioEnabled -> "未启用"
    !health.microphoneCaptureExpected -> "未开启麦克风采集"
    !health.microphoneGranted -> "需要麦克风权限"
    health.audioSilenced -> "暂时收不到声音，请检查麦克风占用和系统麦克风开关"
    health.audioRunning == true -> "录音服务运行中"
    health.audioStarting -> "正在启动"
    health.audioRunning == null -> "暂时无法检查"
    else -> "当前未运行，需要手动开始"
}

internal fun sourceStatus(source: SourceHealth, health: CollectionHealth): String = when {
    !source.enabled -> "未启用"
    health.paused -> "已暂停"
    !source.granted -> "需要授权"
    else -> "已启用"
}
