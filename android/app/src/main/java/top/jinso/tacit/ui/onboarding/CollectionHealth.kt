package top.jinso.tacit.ui.onboarding

/** Observed facts only. Enabled means intent, never proof that a service is running. */
internal data class CollectionHealth(
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
internal enum class RecoveryAction { MICROPHONE, AUDIO, NOTIFICATIONS }
internal data class RecoveryIssue(val title: String, val detail: String, val action: RecoveryAction)

internal fun recoveryIssues(health: CollectionHealth): List<RecoveryIssue> = buildList {
    if (health.microphoneCaptureExpected) {
        when {
            !health.microphoneGranted -> add(RecoveryIssue("麦克风尚未允许", "请在设置中允许麦克风，再到录音页手动开始。", RecoveryAction.MICROPHONE))
            health.audioRunning == null -> add(RecoveryIssue("暂时无法检查录音", "请到录音页检查权限、模型和存储状态。", RecoveryAction.AUDIO))
            health.audioSilenced -> add(RecoveryIssue("录音暂时收不到声音", "检查其他应用是否占用麦克风，或系统是否关闭了麦克风访问。录音服务会等待系统恢复。", RecoveryAction.AUDIO))
            !health.audioRunning && !health.audioStarting -> add(RecoveryIssue("录音当前未运行", "重启或系统停止后，需要回到录音页手动开始。已有录音仍保留。", RecoveryAction.AUDIO))
        }
    }

    if (health.microphoneCaptureExpected &&
        (health.notificationsEnabled == false || health.audioChannel == ChannelAccess.BLOCKED)) {
        add(RecoveryIssue("运行通知未完全开启", "录音服务可能仍在运行，请检查 Tacit 的通知设置。", RecoveryAction.NOTIFICATIONS))
    }
}
