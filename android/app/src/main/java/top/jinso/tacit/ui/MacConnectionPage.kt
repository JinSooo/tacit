package top.jinso.tacit.ui

import top.jinso.tacit.R
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.sync.MacStatus
import top.jinso.tacit.sync.rejectedRecordCategories
import top.jinso.tacit.sync.syncError
import top.jinso.tacit.ui.components.*

@Composable internal fun MacConnectionPage(app: TacitApp) {
    val format = uiFormat()
    val strings = uiStrings()
    val scope = rememberCoroutineScope()
    val activity = LocalActivity.current ?: return
    var status by remember { mutableStateOf<MacStatus?>(null) }
    var address by remember { mutableStateOf<String?>(null) }
    var invite by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var connecting by remember { mutableStateOf(false) }
    var relayWaiting by remember { mutableStateOf(false) }
    var longWait by remember { mutableStateOf(false) }
    var actionJob by remember { mutableStateOf<Job?>(null) }
    LaunchedEffect(relayWaiting) {
        if (relayWaiting) { delay(30_000); longWait = true }
    }
    var expanded by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    LaunchedEffect(app, expanded) {
        try {
            val vault = withContext(Dispatchers.IO) { app.vault }
            merge(vault.changes, vault.syncChanges).collectLatest { status = app.sync.status(expanded) }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            message = strings.text(R.string.connection_unavailable) to true
        }
    }

    val displayAddress = address ?: status?.manual.orEmpty()
    fun action(pairing: Boolean = false, block: suspend () -> Unit) {
        if (busy) return
        message = null
        busy = true
        connecting = pairing
        actionJob = scope.launch {
            try { block() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                val problem = syncError(error, pairing)
                message = strings.text(problem.label) to (pairing || !problem.waiting)
            } finally {
                busy = false
                connecting = false
                relayWaiting = false
                longWait = false
            }
        }
    }
    fun pair(value: String) = action(pairing = true) {
        invite = value
        app.sync.pair(value, displayAddress) { withContext(Dispatchers.Main) { relayWaiting = true } }
        invite = ""
        address = null
    }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let(::pair)
    }
    fun scan() {
        scanner.launch(ScanOptions().setCaptureActivity(InviteScannerActivity::class.java)
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt(strings.text(R.string.scan_mac_qr)).setBeepEnabled(false).setBarcodeImageEnabled(false))
    }
    val recoverPermission = rememberPermissionRecovery { message = it to true }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scan() else recoverPermission(Manifest.permission.CAMERA, strings.text(R.string.camera_ungranted))
    }

    var manualOpen by remember { mutableStateOf(false) }
    val current = status
    val connected = current?.name != null && !current.removed
    if (current != null && connected) {
        GroupCard {
            SettingsRow(current.name.orEmpty(),
                status = if (current.lastSync == 0L) strings.text(R.string.not_yet_synced) else strings.text(R.string.last_sync_at, format.dateAndClock(current.lastSync)))
            if (current.pending > 0) {
                GroupDivider()
                SettingsRow(strings.text(R.string.pending_upload), value = strings.quantity(R.plurals.record_count, current.pending, countLabel(current.pending)))
            }
            val rejected = current.rejected.values.sum()
            if (rejected > 0) {
                GroupDivider()
                SettingsRow(strings.text(R.string.upload_rejected), value = strings.quantity(R.plurals.record_count, rejected, countLabel(rejected)), problem = true,
                    expanded = expanded, onClick = { expanded = !expanded })
                val reasons = remember(current.rejected) { rejectedRecordCategories(current.rejected.filterKeys(String::isNotEmpty)) }
                val shownReasons = rememberLatest(reasons.takeIf { it.isNotEmpty() })
                Reveal(expanded) {
                    shownReasons.orEmpty().forEach { (reason, count) ->
                        GroupDivider()
                        SettingsRow(strings.text(reason), value = strings.quantity(R.plurals.record_count, count, countLabel(count)))
                    }
                }
            }
            GroupDivider()
            SettingsRow(strings.text(R.string.mac_address), value = current.manual.ifBlank { strings.text(R.string.automatic) }, expanded = manualOpen,
                onClick = { manualOpen = !manualOpen })
            Reveal(manualOpen) {
                Column(
                    Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    MacAddressField(displayAddress, { address = it }, busy)
                    Reveal(displayAddress != current.manual) {
                        TonalButton(strings.text(R.string.save_address), { action { app.sync.updateManual(displayAddress); address = null } }, enabled = !busy)
                    }
                }
            }
        }
        if (current.relayDisabled) Caption(strings.text(R.string.relay_disabled))
    } else if (current != null) {
        if (current.removed) {
            Caption(strings.text(R.string.mac_removed), color = tacitColors.attention)
        } else {
            Caption(strings.text(R.string.connection_hint))
        }
        GroupCard {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton(strings.text(R.string.connect_scan), {
                    if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) scan()
                    else permission.launch(Manifest.permission.CAMERA)
                }, enabled = !busy)
                val link = invite.trim()
                val linkValid = link.startsWith("tacit://pair?d=") && link.length > "tacit://pair?d=".length
                val linkInvalid = link.isNotEmpty() && !linkValid
                OutlinedTextField(invite, { invite = it.take(16_400) }, Modifier.fillMaxWidth(),
                    enabled = !busy, label = { Text(strings.text(R.string.invite_link)) }, placeholder = { Text(strings.text(R.string.invite_paste)) },
                    singleLine = true, isError = linkInvalid,
                    supportingText = if (linkInvalid) {{ Text(strings.text(R.string.invite_format_hint)) }} else null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done,
                        autoCorrectEnabled = false))
                TonalButton(strings.text(R.string.connect), { pair(link) }, enabled = linkValid && !busy)
            }
            GroupDivider()
            SettingsRow(strings.text(R.string.mac_address), expanded = manualOpen, onClick = { manualOpen = !manualOpen })
            Reveal(manualOpen) {
                Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp)) {
                    MacAddressField(displayAddress, { address = it }, busy)
                }
            }
        }
    }

    val problem = message ?: current?.error?.let { strings.text(it.label) to !it.waiting }
    val shownProblem = rememberLatest(problem)
    Reveal(problem != null) {
        shownProblem?.let { (text, needsAttention) ->
            Caption(text, color = if (needsAttention) tacitColors.attention else tacitColors.muted)
        }
    }
    if (busy || (current == null && message == null)) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (connecting) Caption(strings.text(if (longWait) R.string.confirm_mac_online else R.string.connecting_mac))
            if (relayWaiting) TextAction(strings.text(R.string.cancel), { actionJob?.cancel() })
            ProgressLine()
        }
    }
    var confirmDisconnect by rememberSaveable { mutableStateOf(false) }
    if (connected) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
            TextAction(strings.text(R.string.disconnect), { confirmDisconnect = true }, enabled = !busy, color = tacitColors.attention)
        }
        if (confirmDisconnect) AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text(strings.text(R.string.disconnect_title)) },
            text = { Text(strings.text(R.string.disconnect_message)) },
            confirmButton = {
                TextAction(strings.text(R.string.disconnect_confirm), {
                    confirmDisconnect = false
                    action { app.sync.disconnect(); address = null; expanded = false }
                }, enabled = !busy, color = tacitColors.attention)
            },
            dismissButton = { TextAction(strings.text(R.string.cancel), { confirmDisconnect = false }) },
        )
    }
    // 被 Mac 移除后不想再连回去时，能清掉旧连接回到手机单独用，不然首页一直挂着提示。
    if (current?.removed == true) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
            TextAction(strings.text(R.string.delete_old_connection), { confirmDisconnect = true }, enabled = !busy, color = tacitColors.attention)
        }
        if (confirmDisconnect) AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text(strings.text(R.string.delete_old_connection_title)) },
            text = { Text(strings.text(R.string.delete_old_connection_message)) },
            confirmButton = {
                TextAction(strings.text(R.string.delete), {
                    confirmDisconnect = false
                    action { app.sync.disconnect(); address = null; expanded = false }
                }, enabled = !busy, color = tacitColors.attention)
            },
            dismissButton = { TextAction(strings.text(R.string.cancel), { confirmDisconnect = false }) },
        )
    }
}

@Composable
private fun MacAddressField(address: String, update: (String) -> Unit, busy: Boolean) {
    val strings = uiStrings()
    OutlinedTextField(address, { update(it.take(512)) }, Modifier.fillMaxWidth(),
        enabled = !busy, label = { Text(strings.text(R.string.mac_address)) }, placeholder = { Text(strings.text(R.string.address_empty_hint)) }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
}
