package top.jinso.tacit.ui.onboarding

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import top.jinso.tacit.ui.components.*

internal fun backgroundProblemCount(health: CollectionHealth): Int {
    if (!health.audioEnabled || !health.audioCaptureWanted) return 0
    return listOf(
        !health.microphoneGranted,
        health.notificationsEnabled == false,
        health.audioChannel == ChannelAccess.BLOCKED,
        health.batteryExempt == false,
        health.backgroundRestricted == true,
        health.powerSave == true,
    ).count { it }
}

@Composable
internal fun BackgroundChecklist(
    health: CollectionHealth?,
    onOpenMicrophone: () -> Unit,
    onRequestNotifications: () -> Unit,
    notify: (String) -> Unit,
) {
    val context = LocalContext.current
    if (health == null) {
        ProgressLine()
        return
    }
    fun open(page: SystemPage) = openSystemPage(context, page, notify)
    GroupCard {
        if (health.microphoneCaptureExpected) {
            CheckItem("麦克风", health.microphoneGranted, "未授权", "打开") { onOpenMicrophone() }
            GroupDivider()
        }
        val allowed = health.notificationsEnabled
        val mark = checkMark(allowed)
        SettingsRow(
            "运行通知",
            when (allowed) { true -> null; false -> "通知未开启"; null -> "暂时无法检查" },
            problem = mark == Mark.PROBLEM, leading = { StatusMark(mark) },
        ) {
            if (allowed != true) {
                if (health.notificationPermissionMissing) TonalButton("允许", onRequestNotifications)
                else TonalButton("打开", { open(SystemPage.NOTIFICATIONS) })
            }
        }
        GroupDivider()
        if (health.audioChannel == ChannelAccess.BLOCKED) {
            CheckItem("录音通知", false, "通知已关闭", "打开") { open(SystemPage.NOTIFICATIONS) }
            GroupDivider()
        }
        CheckItem("电池优化", health.batteryExempt, "待机时录音可能被系统暂停", "打开") {
            open(SystemPage.BATTERY_OPTIMIZATION)
        }
        GroupDivider()
        CheckItem("后台限制", health.backgroundRestricted?.not(), "后台录音可能被系统停止", "打开") {
            open(SystemPage.APP)
        }
        GroupDivider()
        CheckItem("省电模式", health.powerSave?.not(), "开启时录音可能被系统暂停", "打开") {
            open(SystemPage.BATTERY_SAVER)
        }
        GroupDivider()
        // The system exposes no autostart flag.
        SettingsRow("自启动", "系统无法查询，请在应用信息里确认", leading = { StatusMark(Mark.UNKNOWN) }) {
            TonalButton("打开", { open(SystemPage.APP) })
        }
        GroupDivider()
        SettingsRow("最近任务锁定", "在最近任务里长按 Tacit 卡片并锁定", leading = { StatusMark(Mark.UNKNOWN) })
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
