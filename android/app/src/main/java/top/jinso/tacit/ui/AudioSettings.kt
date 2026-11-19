package top.jinso.tacit.ui

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.*
import java.util.concurrent.CompletableFuture

/** Model controls live only in Settings; opening this page never starts a download. */
@Composable internal fun SpeechSettings(app: TacitApp, notify: (String) -> Unit) {
    val audio = remember(app) { AudioController(app) }
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    fun work(task: () -> CompletableFuture<Unit>, success: String) {
        scope.launch {
            busy = true
            try { withContext(Dispatchers.IO) { task().get() }; notify(success) }
            catch (_: Exception) { notify("操作未完成，请检查状态后重试") }
            finally { busy = false }
        }
    }
    var state by remember { mutableStateOf(audio.state()) }
    var preparation by remember { mutableStateOf(audio.modelPreparation()) }
    val models = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val uri = result.data?.data
        if (result.resultCode == Activity.RESULT_OK && uri != null)
            work({ audio.importModels(uri) }, "本地语音模型已就绪")
    }
    LaunchedEffect(audio) {
        while (true) { state = audio.state(); preparation = audio.modelPreparation(); delay(250) }
    }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(if(state.modelsReady)"模型已就绪" else "尚未安装语音模型",color=MaterialTheme.colorScheme.onSurfaceVariant)
        Text("SenseVoice 语音转写、语音检测和声纹识别，共 279.8 MB。仅下载模型，录音与记录不上传。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        Text("来源：sherpa-onnx 官方 GitHub / Hugging Face。下载后校验 SHA-256，并在本机加载成功后启用。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        if(preparation.busy) {
            if(preparation.phase == SpeechPreparationPhase.DOWNLOADING) {
                LinearProgressIndicator(progress = { (preparation.receivedBytes.toFloat() / preparation.totalBytes).coerceIn(0f,1f) }, modifier = Modifier.fillMaxWidth())
                Text(java.lang.String.format(java.util.Locale.ROOT,"%.1f / %.1f MB",preparation.receivedBytes/1_000_000.0,preparation.totalBytes/1_000_000.0),style=MaterialTheme.typography.bodySmall)
            } else LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(if(preparation.phase == SpeechPreparationPhase.DOWNLOADING && !preparation.cancelling) "正在下载语音模型" else preparation.message,style=MaterialTheme.typography.bodySmall)
            if(preparation.phase != SpeechPreparationPhase.IMPORTING) TextButton(onClick={audio.cancelModelDownload();preparation=audio.modelPreparation()},enabled=preparation.canCancel) { Text(if(preparation.cancelling)"正在取消" else "取消下载") }
        } else {
            if(preparation.message.isNotEmpty()) Text(preparation.message,color=if(preparation.phase == SpeechPreparationPhase.ERROR)MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick={runCatching{audio.downloadModels()}.onFailure{notify("模型正在准备，请稍后重试")};preparation=audio.modelPreparation()},enabled=!busy&&!state.recording) {
                Text(when { preparation.phase == SpeechPreparationPhase.ERROR -> "重试下载（279.8 MB）"; state.modelsReady -> "重新下载模型（279.8 MB）"; else -> "下载语音模型（279.8 MB）" })
            }
        }
        TextButton(onClick={models.launch(android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT_TREE).putExtra(android.content.Intent.EXTRA_LOCAL_ONLY,true).addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION))},enabled=!busy&&!state.recording&&!preparation.busy){Text(if(state.modelsReady)"更换模型文件夹" else "导入模型文件夹")}
        if(audio.supportsNpu()) {
            Text(audio.accelerationState(),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            Text("此手机可另下载 162 MB 的 SenseVoice 加速模型。加载并运行成功后启用 NPU，失败时继续使用 CPU。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick={runCatching{audio.downloadAcceleration()}.onFailure{notify(it.message?:"暂时无法准备加速模型")};preparation=audio.modelPreparation()},enabled=state.modelsReady&&!busy&&!state.recording&&!preparation.busy){Text("准备本机加速（162 MB）")}
        }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun AudioStorageSettings(app: TacitApp, notify: (String) -> Unit) {
    val audio = remember(app) { AudioController(app) }
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    fun work(task: () -> CompletableFuture<Unit>, success: String) {
        scope.launch {
            busy = true
            try { withContext(Dispatchers.IO) { task().get() }; notify(success) }
            catch (_: Exception) { notify("操作未完成，请检查状态后重试") }
            finally { busy = false }
        }
    }
    var count by remember { mutableIntStateOf(0) }
    var clear by remember { mutableStateOf(false) }
    var days by remember { mutableStateOf(app.prefs.retentionDays.toString()) }
    LaunchedEffect(audio, busy) {
        if (!busy) withContext(Dispatchers.IO) { runCatching { audio.listClips().get().size }.getOrNull() }?.let { count = it }
    }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("本机保留 $count 段录音",color=MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            OutlinedTextField(days,{days=it.filter{c->c.isDigit()}.take(2)},Modifier.width(120.dp),label={Text("保留天数")},singleLine=true)
            TextButton(onClick={val value=days.toIntOrNull();if(value!=null&&value in 1..90){app.prefs.retentionDays=value;work({audio.prune()},"已更新保留期")}else notify("请输入 1 至 90 天")},enabled=!busy){Text("保存")}
        }
        TextButton(onClick={clear=true},enabled=!busy){Text("清理录音和声纹",color=MaterialTheme.colorScheme.error)}
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
    if(clear)AlertDialog(onDismissRequest={clear=false},title={Text("清理本机录音和声纹？")},text={Text("全部录音和声音标记将永久删除。已生成的文字记录保留，可在历史记录中单独删除。")},confirmButton={TextButton(onClick={clear=false;work({audio.clearAudio()},"录音和声纹已清理")}){Text("清理",color=MaterialTheme.colorScheme.error)}},dismissButton={TextButton(onClick={clear=false}){Text("取消")}})
}
