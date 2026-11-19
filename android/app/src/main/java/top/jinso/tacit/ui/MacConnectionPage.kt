package top.jinso.tacit.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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

@OptIn(ExperimentalLayoutApi::class)
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

    val current = status
    val connected = current?.name != null && !current.removed
    if (connected) {
        Text("已连接 ${current.name}", style = MaterialTheme.typography.titleLarge)
        Text(if (current.lastSync == 0L) "尚未同步" else "上次同步 ${date(current.lastSync, "M 月 d 日 HH:mm")}",
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("待发送 ${current.pending} 条")
        val rejected = current.rejected.values.sum()
        if (rejected > 0) {
            TextButton(onClick = { expanded = !expanded }) {
                Text("被拒 $rejected 条，${if (expanded) "收起原因" else "查看原因"}")
            }
            if (expanded) current.rejected.filterKeys(String::isNotEmpty).forEach { (reason, count) ->
                Text("$count 条，$reason", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else Text("被拒 0 条", color = MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider()
    } else if (current?.removed == true) {
        Text("已在 Mac 上移除，需重新配对", color = MaterialTheme.colorScheme.error)
    } else if (current != null) {
        Text("在 Mac 的 Tacit 设置中生成配对邀请。连接后，这台手机的记录会同步到 Mac。",
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }

    if (current != null) {
        OutlinedTextField(displayAddress, { address = it.take(512) }, Modifier.fillMaxWidth(),
            enabled = !busy, label = { Text("Mac 地址（可选）") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        if (connected) {
            if (displayAddress != current.manual) {
                Button(onClick = { action { app.sync.updateManual(displayAddress); address = null } }, enabled = !busy) {
                    Text("保存地址")
                }
            }
        } else {
            OutlinedTextField(invite, { invite = it.take(16_400) }, Modifier.fillMaxWidth(),
                enabled = !busy, label = { Text("配对链接") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { pair(invite) }, enabled = invite.isNotBlank() && !busy) { Text("连接") }
                TextButton(onClick = {
                    if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) scan()
                    else permission.launch(Manifest.permission.CAMERA)
                }, enabled = !busy) { Text("扫码") }
            }
        }
        if (current.name != null) TextButton(onClick = {
            action { app.sync.disconnect(); address = null; expanded = false }
        }, enabled = !busy) { Text("断开连接", color = MaterialTheme.colorScheme.error) }
    }
    (message ?: current?.error)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
}
