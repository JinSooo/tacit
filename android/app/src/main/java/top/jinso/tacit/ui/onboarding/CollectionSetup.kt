package top.jinso.tacit.ui.onboarding

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/** Small enough to place above History or Audio. Navigation, never automatic recovery. */
@Composable
internal fun CollectionRecoveryNotice(
    health: CollectionHealth,
    onOpenSource: (String?) -> Unit,
    onOpenAudio: () -> Unit,
    notify: (String) -> Unit,
) {
    val issues = recoveryIssues(health)
    val first = issues.firstOrNull() ?: return
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(first.title, style = MaterialTheme.typography.titleLarge)
        Text(first.detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = {
            when (first.action) {
                RecoveryAction.SOURCE -> onOpenSource(first.source)
                RecoveryAction.AUDIO -> onOpenAudio()
                RecoveryAction.NOTIFICATIONS -> openSystemPage(context, SystemPage.NOTIFICATIONS, notify)
            }
        }) {
            Text(when (first.action) {
                RecoveryAction.SOURCE -> "检查权限与采集"
                RecoveryAction.AUDIO -> "查看录音"
                RecoveryAction.NOTIFICATIONS -> "检查运行通知"
            })
        }
        if (issues.size > 1) TextButton(onClick = { onOpenSource(null) }) { Text("还有 ${issues.size - 1} 项，逐项检查") }
    }
}

@Composable
internal fun PermissionChecklist(health: CollectionHealth, onOpenSource: (String) -> Unit, onOpenAudio: () -> Unit) {
    val enabled = health.sources.filter { it.enabled }
    if (enabled.isEmpty() && !health.audioEnabled) {
        Text("还没有开启采集来源。可以先返回设置选一种来源，也可以直接补写记录。", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    enabled.forEach { source ->
        SetupItem(source.name, source.permissionText, "检查${source.name}") { onOpenSource(source.id) }
    }
    if (health.microphoneCaptureExpected) {
        SetupItem("麦克风", audioPermissionText(health), "检查麦克风") { onOpenSource("android.audio") }
    } else {
        SetupItem("录音", audioPermissionText(health), "查看录音", onOpenAudio)
    }
}

@Composable
internal fun NotificationSetup(health: CollectionHealth, onRequest: () -> Unit, notify: (String) -> Unit) {
    val context = LocalContext.current
    SetupItem("Tacit 的运行通知", when (health.notificationsEnabled) {
        true -> "应用通知已允许。与读取其他应用通知的权限是两回事。"
        false -> "应用通知未允许。录音服务可能仍运行，但通知栏可能不显示。"
        null -> "暂时无法检查应用通知，请打开系统设置确认。"
    }, if (health.notificationsEnabled == false) "允许运行通知" else "检查通知设置", onRequest)
    // After repeated denials Android may stop showing the runtime prompt. Keep a direct exit.
    if (health.notificationsEnabled == false) TextButton(onClick = {
        openSystemPage(context, SystemPage.NOTIFICATIONS, notify)
    }) { Text("打开系统通知设置") }
    fun channelText(access: ChannelAccess) = when (access) {
        ChannelAccess.NOT_CREATED -> "首次启动服务后创建，尚无系统设置"
        ChannelAccess.ALLOWED -> if (health.notificationsEnabled == true) "通知类别已允许" else "通知类别已允许，仍受应用通知总开关控制"
        ChannelAccess.BLOCKED -> "通知类别已关闭"
        ChannelAccess.UNKNOWN -> "暂时无法检查"
    }
    Text("录音通知：${channelText(health.audioChannel)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (health.audioChannel == ChannelAccess.BLOCKED) {
        TextButton(onClick = { openSystemPage(context, SystemPage.NOTIFICATIONS, notify) }) { Text("打开通知类别设置") }
    }
}

@Composable
internal fun BackgroundSetup(health: CollectionHealth, notify: (String) -> Unit) {
    val context = LocalContext.current
    SetupItem("系统电池优化", when (health.batteryExempt) {
        true -> "已豁免系统电池优化，仍不保证持续运行。"
        false -> "未豁免，待机时可能延迟采集。需要持续记录时，可在系统列表中检查 Tacit。"
        null -> "暂时无法检查，请在系统设置中确认。"
    }, "检查电池优化") { openSystemPage(context, SystemPage.BATTERY_OPTIMIZATION, notify) }
    SetupItem("后台限制", when (health.backgroundRestricted) {
        true -> "系统已限制 Tacit 的后台活动，可能中断或延迟采集。"
        false -> "系统未报告后台限制，厂商的额外限制需手动检查。"
        null -> "暂时无法检查，请在应用信息中确认。"
    }, "检查应用电量设置") { openSystemPage(context, SystemPage.APP, notify) }
    SetupItem("省电模式", when (health.powerSave) {
        true -> "系统省电模式已开启，后台采集可能延迟。"
        false -> "系统省电模式未开启。"
        null -> "暂时无法检查，请在系统设置中确认。"
    }, "检查省电模式") { openSystemPage(context, SystemPage.BATTERY_SAVER, notify) }
    Text("小米手机再检查两处", style = MaterialTheme.typography.titleLarge)
    Text("在系统设置中搜索“自启动”，找到 Tacit；需要持续采集时可允许自启动，并在应用电量管理中选择“无限制”。不同系统版本的入口可能不同。", color = MaterialTheme.colorScheme.onSurfaceVariant)
    TextButton(onClick = { openSystemPage(context, SystemPage.APP, notify) }) { Text("打开 Tacit 应用信息") }
    Text("打开最近任务，按住 Tacit 卡片，查看是否有锁定选项。自启动和最近任务锁定没有可靠的通用查询接口，这里不会标为已完成；它们也不会自动恢复录音。", color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun CollectionReady(health: CollectionHealth, onOpenSource: (String) -> Unit, onOpenAudio: () -> Unit) {
    if (health.paused) Text("采集已暂停。需要继续时，请返回设置手动继续。", color = MaterialTheme.colorScheme.onSurfaceVariant)
    health.sources.filter { it.enabled }.forEach { source ->
        SetupItem(source.name, sourceStatus(source, health), "查看采集状态") { onOpenSource(source.id) }
    }
    if (health.audioEnabled) SetupItem("录音",
        audioReadyText(health), "查看录音", onOpenAudio)
    Text("打开来源后，可以返回历史页查看实际入库的记录。系统授权、电池设置和服务运行都不等于已经采集到内容。", color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text("重启手机、暂停采集或被系统停止后，录音需要回到应用内手动开始。返回前台只检查状态，不会替你开启。", color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun SetupItem(title: String, detail: String, action: String, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title)
        Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = onClick) { Text(action) }
    }
}
