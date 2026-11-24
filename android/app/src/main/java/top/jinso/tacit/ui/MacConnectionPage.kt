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
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sync.MacStatus
import top.jinso.tacit.sync.syncError
import top.jinso.tacit.ui.components.*

@Composable internal fun MacConnectionPage(app: TacitApp) {
    val scope = rememberCoroutineScope()
    val activity = LocalActivity.current ?: return
    var status by remember { mutableStateOf<MacStatus?>(null) }
    var address by remember { mutableStateOf<String?>(null) }
    var invite by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(app, expanded) {
        try {
            val vault = withContext(Dispatchers.IO) { app.vault }
            vault.changes.collectLatest { status = app.sync.status(expanded) }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            message = "无法读取连接状态，请检查本机记录库"
        }
    }

    val displayAddress = address ?: status?.manual.orEmpty()
    fun action(pairing: Boolean = false, block: suspend () -> Unit) {
        if (busy) return
        message = null
        busy = true
        scope.launch {
            try { block() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { message = syncError(error, pairing) }
            finally { busy = false }
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
            .setPrompt("扫描 Mac 上的配对二维码").setBeepEnabled(false).setBarcodeImageEnabled(false))
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scan() else message = "未允许相机访问，可以粘贴配对链接"
    }

    var manualOpen by remember { mutableStateOf(false) }
    val current = status
    val connected = current?.name != null && !current.removed
    if (connected) {
        GroupCard {
            SettingsRow(current.name.orEmpty(),
                status = if (current.lastSync == 0L) "尚未同步" else date(current.lastSync, "M 月 d 日 HH:mm") + " 同步")
            // Zero waiting and zero rejected is the normal case, not news.
            if (current.pending > 0) {
                GroupDivider()
                SettingsRow("待发送", value = "${current.pending} 条")
            }
            val rejected = current.rejected.values.sum()
            if (rejected > 0) {
                GroupDivider()
                SettingsRow("被拒", value = "$rejected 条", problem = true,
                    expanded = expanded, onClick = { expanded = !expanded })
                if (expanded) current.rejected.filterKeys(String::isNotEmpty).forEach { (reason, count) ->
                    GroupDivider()
                    SettingsRow(reason, value = "$count 条")
                }
            }
            GroupDivider()
            SettingsRow("Mac 地址", value = current.manual.ifBlank { "自动" }, expanded = manualOpen,
                onClick = { manualOpen = !manualOpen })
            if (manualOpen) Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                MacAddressField(displayAddress, { address = it }, busy)
                if (displayAddress != current.manual) {
                    TonalButton("保存地址", { action { app.sync.updateManual(displayAddress); address = null } }, enabled = !busy)
                }
            }
        }
    } else if (current != null) {
        if (current.removed) Caption("已在 Mac 上移除，需重新配对", color = tacitColors.attention)
        Caption("在 Mac 的 Tacit 设置里生成配对邀请。")
        PrimaryButton("扫码连接", {
            if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) scan()
            else permission.launch(Manifest.permission.CAMERA)
        }, enabled = !busy)
        GroupCard {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(invite, { invite = it.take(16_400) }, Modifier.fillMaxWidth(),
                    enabled = !busy, label = { Text("粘贴配对链接") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                TonalButton("连接", { pair(invite) }, enabled = invite.isNotBlank() && !busy)
            }
            GroupDivider()
            SettingsRow(if (manualOpen) "收起 Mac 地址" else "手动填写 Mac 地址", expanded = manualOpen, onClick = { manualOpen = !manualOpen })
            if (manualOpen) Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp)) {
                MacAddressField(displayAddress, { address = it }, busy)
            }
        }
    }

    (message ?: current?.error)?.let { Caption(it, color = tacitColors.attention) }
    if (busy || (current == null && message == null)) ProgressLine()
    var confirmDisconnect by rememberSaveable { mutableStateOf(false) }
    if (current?.name != null) {
        TextAction("断开连接", { confirmDisconnect = true }, enabled = !busy, color = tacitColors.attention)
        if (confirmDisconnect) AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text("断开连接？") },
            text = { Text("本机录音会保留，重新连接要在 Mac 上再扫一次码。") },
            confirmButton = {
                TextAction("断开", {
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
