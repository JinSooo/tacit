package top.jinso.tacit.ui.onboarding

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import top.jinso.tacit.ui.components.*

@Composable
internal fun CollectionRecoveryNotice(
    health: CollectionHealth,
    onOpenMicrophone: () -> Unit,
    onOpenAudio: () -> Unit,
    notify: (String) -> Unit,
    onAudioPage: Boolean = false,
) {
    // The recording page already shows its own state, so a notice pointing back to it is noise there.
    val issues = recoveryIssues(health).filterNot { onAudioPage && it.action == RecoveryAction.AUDIO }
    val first = issues.firstOrNull() ?: return
    val context = LocalContext.current
    val title = first.title + if (issues.size > 1) "，另有 ${issues.size - 1} 项" else ""
    NoticeRow(title) {
        when (first.action) {
            RecoveryAction.MICROPHONE -> onOpenMicrophone()
            RecoveryAction.AUDIO -> onOpenAudio()
            RecoveryAction.NOTIFICATIONS -> openSystemPage(context, SystemPage.NOTIFICATIONS, notify)
        }
    }
}

internal fun backgroundProblemCount(health: CollectionHealth): Int =
    listOf(
        health.microphoneCaptureExpected && !health.microphoneGranted,
        health.notificationsEnabled == false,
        health.audioChannel == ChannelAccess.BLOCKED,
        health.batteryExempt == false,
        health.backgroundRestricted == true,
        health.powerSave == true,
    ).count { it }

@Composable
internal fun BackgroundChecklist(
    health: CollectionHealth?,
    onOpenMicrophone: () -> Unit,
    onRequestNotifications: () -> Unit,
    notify: (String) -> Unit,
) {
    val context = LocalContext.current
    if (health == null) {
        Caption("正在检查系统状态")
        return
    }
    fun open(page: SystemPage) = openSystemPage(context, page, notify)
    GroupCard {
        if (health.microphoneCaptureExpected) {
            CheckItem("麦克风", health.microphoneGranted, "需要权限", "去设置") { onOpenMicrophone() }
            GroupDivider()
        }
        val allowed = health.notificationsEnabled
        val mark = checkMark(allowed)
        SettingsRow(
            "Tacit 运行通知",
            when (allowed) { true -> null; false -> "通知未开启"; null -> "暂时无法检查" },
            problem = mark == Mark.PROBLEM, leading = { StatusMark(mark) },
            onClick = if (allowed == false) {{ open(SystemPage.NOTIFICATIONS) }} else null,
        ) {
            when (allowed) {
                false -> TonalButton("允许", onRequestNotifications)
                null -> TonalButton("打开", { open(SystemPage.NOTIFICATIONS) })
                true -> Unit
            }
        }
        GroupDivider()
        val channel = health.audioChannel
        val channelMark = when (channel) {
            ChannelAccess.ALLOWED -> Mark.OK
            ChannelAccess.BLOCKED -> Mark.PROBLEM
            else -> Mark.UNKNOWN
        }
        SettingsRow(
            "录音通知类别",
            when (channel) {
                ChannelAccess.ALLOWED -> null
                ChannelAccess.BLOCKED -> "通知类别已关闭"
                ChannelAccess.NOT_CREATED -> "首次录音后创建"
                ChannelAccess.UNKNOWN -> "暂时无法检查"
            },
            problem = channelMark == Mark.PROBLEM,
            leading = { StatusMark(channelMark) },
        ) {
            if (channel != ChannelAccess.ALLOWED && channel != ChannelAccess.NOT_CREATED) {
                TonalButton("打开", { open(SystemPage.NOTIFICATIONS) })
            }
        }
        GroupDivider()
        CheckItem("电池优化", health.batteryExempt, "待机时可能延迟记录", "去设置") {
            open(SystemPage.BATTERY_OPTIMIZATION)
        }
        GroupDivider()
        CheckItem("后台限制", health.backgroundRestricted?.not(), "系统限制后台活动", "去设置") {
            open(SystemPage.APP)
        }
        GroupDivider()
        CheckItem("省电模式", health.powerSave?.not(), "省电模式可能延迟记录", "去设置") {
            open(SystemPage.BATTERY_SAVER)
        }
        GroupDivider()
        // The system exposes no autostart flag.
        SettingsRow("自启动", "系统查不到，请自己确认", leading = { StatusMark(Mark.UNKNOWN) }) {
            TonalButton("打开", { open(SystemPage.APP) })
        }
        GroupDivider()
        SettingsRow("最近任务锁定", "在最近任务里按住 Tacit 卡片", leading = { StatusMark(Mark.UNKNOWN) })
    }
    Caption("手机重启或被系统停止后，打开一次 Tacit 就会接着录。")
}

internal fun checkMark(ok: Boolean?): Mark = when (ok) {
    true -> Mark.OK
    false -> Mark.PROBLEM
    null -> Mark.UNKNOWN
}

@Composable
private fun CheckItem(title: String, ok: Boolean?, no: String, label: String, action: () -> Unit) {
    val mark = checkMark(ok)
    // A check mark already says "fine"; words are only for what still needs a hand.
    val status = when (ok) { true -> null; false -> no; null -> "暂时无法检查" }
    SettingsRow(title, status, problem = mark == Mark.PROBLEM, leading = { StatusMark(mark) }) {
        if (mark != Mark.OK) TonalButton(label, action)
    }
}
