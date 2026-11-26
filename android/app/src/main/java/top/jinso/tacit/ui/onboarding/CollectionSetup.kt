package top.jinso.tacit.ui.onboarding

import top.jinso.tacit.ui.uiStrings
import top.jinso.tacit.R
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
    val strings = uiStrings()
    val context = LocalContext.current
    if (health == null) {
        ProgressLine()
        return
    }
    fun open(page: SystemPage) = openSystemPage(context, page, notify)
    GroupCard {
        if (health.microphoneCaptureExpected) {
            CheckItem(strings.text(R.string.microphone), health.microphoneGranted, strings.text(R.string.permission_missing), strings.text(R.string.open)) { onOpenMicrophone() }
            GroupDivider()
        }
        val allowed = health.notificationsEnabled
        val mark = checkMark(allowed)
        SettingsRow(
            strings.text(R.string.activity_notifications),
            when (allowed) { true -> null; false -> strings.text(R.string.notifications_disabled); null -> strings.text(R.string.status_unknown) },
            problem = mark == Mark.PROBLEM, leading = { StatusMark(mark) },
        ) {
            if (allowed != true) {
                if (health.notificationPermissionMissing) TonalButton(strings.text(R.string.allow), onRequestNotifications)
                else TonalButton(strings.text(R.string.open), { open(SystemPage.NOTIFICATIONS) })
            }
        }
        GroupDivider()
        if (health.audioChannel == ChannelAccess.BLOCKED) {
            CheckItem(strings.text(R.string.recording_notifications), false, strings.text(R.string.notifications_channel_disabled), strings.text(R.string.open)) { open(SystemPage.NOTIFICATIONS) }
            GroupDivider()
        }
        CheckItem(strings.text(R.string.battery_optimization), health.batteryExempt, strings.text(R.string.battery_optimization_hint), strings.text(R.string.open)) {
            open(SystemPage.BATTERY_OPTIMIZATION)
        }
        GroupDivider()
        CheckItem(strings.text(R.string.background_restriction), health.backgroundRestricted?.not(), strings.text(R.string.background_restriction_hint), strings.text(R.string.open)) {
            open(SystemPage.APP)
        }
        GroupDivider()
        CheckItem(strings.text(R.string.power_save), health.powerSave?.not(), strings.text(R.string.power_save_hint), strings.text(R.string.open)) {
            open(SystemPage.BATTERY_SAVER)
        }
        GroupDivider()
        // The system exposes no autostart flag.
        SettingsRow(strings.text(R.string.auto_start), strings.text(R.string.auto_start_hint), leading = { StatusMark(Mark.UNKNOWN) }) {
            TonalButton(strings.text(R.string.open), { open(SystemPage.APP) })
        }
        GroupDivider()
        SettingsRow(strings.text(R.string.lock_recents), strings.text(R.string.lock_recents_hint), leading = { StatusMark(Mark.UNKNOWN) })
    }
    Caption(strings.text(R.string.recording_restart_hint))
}

internal fun checkMark(ok: Boolean?): Mark = when (ok) {
    true -> Mark.OK
    false -> Mark.PROBLEM
    null -> Mark.UNKNOWN
}

@Composable
private fun CheckItem(title: String, ok: Boolean?, no: String, label: String, action: () -> Unit) {
    val strings = uiStrings()
    val mark = checkMark(ok)
    // A check mark already says "fine"; words are only for what still needs a hand.
    val status = when (ok) { true -> null; false -> no; null -> strings.text(R.string.status_unknown) }
    SettingsRow(title, status, problem = mark == Mark.PROBLEM, leading = { StatusMark(mark) }) {
        if (mark != Mark.OK) TonalButton(label, action)
    }
}
