package top.jinso.tacit.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sync.MacStatus
import top.jinso.tacit.sync.isSyncWaiting
import top.jinso.tacit.sync.rejectedRecordCategories
import top.jinso.tacit.sync.syncError
import top.jinso.tacit.ui.components.*

@Composable internal fun MacConnectionPage(app: TacitApp) {
    val scope = rememberCoroutineScope()
    val activity = LocalActivity.current ?: return
    var status by remember { mutableStateOf<MacStatus?>(null) }
    var address by remember { mutableStateOf<String?>(null) }
    var invite by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var connecting by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    LaunchedEffect(app, expanded) {
        try {
            val vault = withContext(Dispatchers.IO) { app.vault }
            merge(vault.changes, vault.syncChanges).collectLatest { status = app.sync.status(expanded) }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            message = "无法读取连接状态，请检查本机记录库" to true
        }
    }

    val displayAddress = address ?: status?.manual.orEmpty()
    fun action(pairing: Boolean = false, block: suspend () -> Unit) {
        if (busy) return
        message = null
        busy = true
        connecting = pairing
        scope.launch {
            try { block() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                val text = syncError(error, pairing)
                message = text to !isSyncWaiting(text, pairing)
            } finally {
                busy = false
                connecting = false
            }
        }
    }
    fun pair(value: String) = action(pairing = true) {
        app.sync.pair(value, displayAddress)
        invite = ""
        address = null
    }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let(::pair)
    }
    fun scan() {
        scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt("扫描 Mac 上的二维码").setBeepEnabled(false).setBarcodeImageEnabled(false))
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scan() else message = "相机未授权，可以粘贴邀请链接" to true
    }

    var manualOpen by remember { mutableStateOf(false) }
    val current = status
    val connected = current?.name != null && !current.removed
    if (current != null && connected) {
        GroupCard {
            SettingsRow(current.name.orEmpty(),
                status = if (current.lastSync == 0L) "尚未同步" else date(current.lastSync, "M 月 d 日 HH:mm") + " 同步")
            if (current.pending > 0) {
                GroupDivider()
                SettingsRow("待发送", value = "${countLabel(current.pending)} 条")
            }
            val rejected = current.rejected.values.sum()
            if (rejected > 0) {
                GroupDivider()
                SettingsRow("未能接收", value = "${countLabel(rejected)} 条", problem = true,
                    expanded = expanded, onClick = { expanded = !expanded })
                val reasons = remember(current.rejected) { rejectedRecordCategories(current.rejected.filterKeys(String::isNotEmpty)) }
                val shownReasons = rememberLatest(reasons.takeIf { it.isNotEmpty() })
                Reveal(expanded) {
                    shownReasons.orEmpty().forEach { (reason, count) ->
                        GroupDivider()
                        SettingsRow(reason, value = "${countLabel(count)} 条")
                    }
                }
            }
            GroupDivider()
            SettingsRow("Mac 地址", value = current.manual.ifBlank { "自动" }, expanded = manualOpen,
                onClick = { manualOpen = !manualOpen })
            Reveal(manualOpen) {
                Column(
                    Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    MacAddressField(displayAddress, { address = it }, busy)
                    Reveal(displayAddress != current.manual) {
                        TonalButton("保存地址", { action { app.sync.updateManual(displayAddress); address = null } }, enabled = !busy)
                    }
                }
            }
        }
        if (current.relayDisabled) Caption("中转信箱已停用，回到和 Mac 同一个网络后会自动同步。")
    } else if (current != null) {
        if (current.removed) {
            Caption("已在 Mac 上移除，请在 Mac 的 Tacit 里重新添加这台手机。", color = tacitColors.attention)
        } else {
            Caption("在 Mac 的 Tacit 设置里添加设备，获取二维码或邀请链接。")
        }
        GroupCard {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton("扫码连接", {
                    if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) scan()
                    else permission.launch(Manifest.permission.CAMERA)
                }, enabled = !busy)
                OutlinedTextField(invite, { invite = it.take(16_400) }, Modifier.fillMaxWidth(),
                    enabled = !busy, label = { Text("邀请链接") }, placeholder = { Text("粘贴邀请链接") },
                    singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                TonalButton("连接", { pair(invite) }, enabled = invite.isNotBlank() && !busy)
            }
            GroupDivider()
            SettingsRow("Mac 地址", expanded = manualOpen, onClick = { manualOpen = !manualOpen })
            Reveal(manualOpen) {
                Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp)) {
                    MacAddressField(displayAddress, { address = it }, busy)
                }
            }
        }
    }

    val problem = message ?: current?.error?.let { it to !isSyncWaiting(it) }
    val shownProblem = rememberLatest(problem)
    Reveal(problem != null) {
        shownProblem?.let { (text, needsAttention) ->
            Caption(text, color = if (needsAttention) tacitColors.attention else tacitColors.muted)
        }
    }
    if (busy || (current == null && message == null)) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (connecting) Caption("正在连接 Mac…")
            ProgressLine()
        }
    }
    var confirmDisconnect by rememberSaveable { mutableStateOf(false) }
    if (connected) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
            TextAction("断开连接", { confirmDisconnect = true }, enabled = !busy, color = tacitColors.attention)
        }
        if (confirmDisconnect) AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text("断开连接？") },
            text = { Text("本机录音会保留，已同步的 Mac 内容会从手机清除，重新连接需在 Mac 上重新生成邀请。") },
            confirmButton = {
                TextAction("断开", {
                    confirmDisconnect = false
                    action { app.sync.disconnect(); address = null; expanded = false }
                }, enabled = !busy, color = tacitColors.attention)
            },
            dismissButton = { TextAction("取消", { confirmDisconnect = false }) },
        )
    }
    // 被 Mac 移除后不想再连回去时，能清掉旧连接回到手机单独用，不然首页一直挂着提示。
    if (current?.removed == true) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
            TextAction("删除旧连接", { confirmDisconnect = true }, enabled = !busy, color = tacitColors.attention)
        }
        if (confirmDisconnect) AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text("删除旧连接？") },
            text = { Text("会删除这台 Mac 的连接记录，本机录音会保留。") },
            confirmButton = {
                TextAction("删除", {
                    confirmDisconnect = false
                    action { app.sync.disconnect(); address = null; expanded = false }
                }, enabled = !busy, color = tacitColors.attention)
            },
            dismissButton = { TextAction("取消", { confirmDisconnect = false }) },
        )
    }
}

@Composable
private fun MacAddressField(address: String, update: (String) -> Unit, busy: Boolean) {
    OutlinedTextField(address, { update(it.take(512)) }, Modifier.fillMaxWidth(),
        enabled = !busy, label = { Text("Mac 地址") }, placeholder = { Text("留空自动发现") }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
}
