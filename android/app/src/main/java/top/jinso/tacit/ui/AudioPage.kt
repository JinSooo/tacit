package top.jinso.tacit.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.activity.compose.LocalActivity
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.*
import top.jinso.tacit.core.HistoryRecord
import java.util.concurrent.CompletableFuture

@OptIn(ExperimentalLayoutApi::class)
@Composable fun AudioPage(
    app: TacitApp,
    resumed: Int,
    notify: (String) -> Unit,
    onOpenSettings: (String) -> Unit = { notify("请在设置中打开语音转写或隐私与存储") },
    onSelectRecord: (HistoryRecord) -> Unit = { notify("请在历史记录中打开这段录音") },
) {
    val activity=LocalActivity.current ?: return
    val audio=remember{AudioController(app)};val scope=rememberCoroutineScope()
    var state by remember{mutableStateOf(audio.state())};var speakers by remember{mutableStateOf(emptyList<AudioSpeaker>())}
    var busy by remember { mutableStateOf(false) }
    var rows by remember { mutableStateOf(emptyList<AudioConversationRow>()) }
    var waitingClips by remember { mutableIntStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    var loadFailed by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf<String?>(null) }
    var includeIgnored by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf<String?>(null) }
    var speakerName by remember { mutableStateOf("") }
    fun work(task:()->CompletableFuture<Unit>,success:String) {scope.launch{busy=true;try{withContext(Dispatchers.IO){task().get()};notify(success)}catch(_:Exception){notify("操作未完成，请检查状态后重试")};busy=false}}
    fun start() {try{app.prefs.setEnabled(AUDIO_SOURCE,true);audio.start(activity);state=audio.state()}catch(_:Exception){notify("无法开始录音，请先授权麦克风并继续采集")}}
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()){result -> if(result[Manifest.permission.RECORD_AUDIO]==true || activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED) start() else notify("麦克风未授权，未开始录音")}
    val owner = activity as? LifecycleOwner
    LaunchedEffect(owner, resumed, includeIgnored) {
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.RESUMED) { while (true) {
            state = audio.state()
            if (!busy) {
                val snapshot = withContext(Dispatchers.IO) {
                    runCatching {
                        val voices = audio.listSpeakers(includeIgnored).get()
                        val scenes = audio.listConversations().get().sortedByDescending { it.start }
                        val text = scenes.flatMap { it.recordIds }.distinct().mapNotNull { app.vault.get(it) }.associateBy { it.id }
                        val waiting = audio.listClips().get().count { it.conversationId == null && !it.analyzed }
                        Triple(voices, audioConversationRows(scenes, text), waiting)
                    }
                }
                snapshot.onSuccess { (voices, conversations, waiting) ->
                    speakers = voices; rows = conversations; waitingClips = waiting
                }
                loadFailed = snapshot.isFailure
                loaded = true
            }
            delay(2000)
        } }
    }
    DisposableEffect(Unit){onDispose{audio.stopPlayback()}}
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item(key = "recording") { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(16.dp)){
            Icon(if(state.recording)Icons.Outlined.GraphicEq else Icons.Outlined.MicNone,null,Modifier.size(32.dp),tint=if(state.recording)MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f)){Text(if(state.recording)"正在录音" else "记录身边的对话",style=MaterialTheme.typography.titleLarge);Text(state.message,color=MaterialTheme.colorScheme.onSurfaceVariant)}
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Button(onClick={if(state.recording){audio.stop();state=audio.state()}else{val permissions=mutableListOf(Manifest.permission.RECORD_AUDIO);if(Build.VERSION.SDK_INT>=33)permissions+=Manifest.permission.POST_NOTIFICATIONS;permission.launch(permissions.toTypedArray())}},enabled=!busy){Icon(if(state.recording)Icons.Outlined.Stop else Icons.Outlined.Mic,null,Modifier.size(20.dp));Spacer(Modifier.width(8.dp));Text(if(state.recording)"停止录音" else "开始录音")}
        }
        Text("录音加密保存在手机，只转写有你声音的对话。", style=MaterialTheme.typography.bodySmall, color=MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
            TextButton(onClick={onOpenSettings(SettingsRoutes.SPEECH)}) { Text(if(state.modelsReady) "语音转写" else "准备语音转写") }
            TextButton(onClick={onOpenSettings(SettingsRoutes.RETENTION)}) { Text("保留与清理") }
        }

        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        HorizontalDivider()
        } }
        item(key = "speakers-title") {
        Row(verticalAlignment=Alignment.CenterVertically){Text("确认声音",Modifier.weight(1f),style=MaterialTheme.typography.titleLarge);TextButton(onClick={includeIgnored=!includeIgnored}){Text(if(includeIgnored)"隐藏已忽略" else "查看已忽略")}}
        }
        if (speakers.isEmpty() && loaded && !loadFailed) item(key = "speakers-empty") {
            Text("录到清晰的说话声后，会在这里请你试听确认。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        items(speakers, key = { "speaker-${it.id}" }) { speaker -> Column(verticalArrangement=Arrangement.spacedBy(4.dp)){
            Text(if(speaker.isMe)"我" else speaker.name?:"待确认的声音 ${speakers.indexOf(speaker)+1}")
            if(speaker.ignored)Text("已忽略",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)){
                TextButton(onClick={work({audio.playSample(speaker.id)},"正在试听")},enabled=speaker.sampleAvailable&&!busy){Text("试听")}
                if(!speaker.isMe && !speaker.ignored)TextButton(onClick={work({audio.markMe(speaker.id)},"已标记为我，将补转写保留期内的录音")},enabled=!busy){Text("这是我")}
                if(speaker.isMe)TextButton(onClick={work({audio.unmarkMe(speaker.id)},"已取消本人标记")},enabled=!busy){Text("这不是我")}
                if(!speaker.isMe)TextButton(onClick={work({audio.setIgnored(speaker.id,!speaker.ignored)},if(speaker.ignored)"已恢复这个声音" else "已忽略这个声音")},enabled=!busy){Text(if(speaker.ignored)"恢复" else "忽略")}
                if(!speaker.isMe && !speaker.ignored)TextButton(onClick={naming=speaker.id;speakerName=speaker.name?:""},enabled=!busy){Text("设置称呼")}
            }

            if(naming==speaker.id){OutlinedTextField(speakerName,{speakerName=it.take(80)},Modifier.fillMaxWidth(),label={Text("如何称呼")},singleLine=true);FlowRow{TextButton(onClick={work({audio.renameSpeaker(speaker.id,speakerName)},"称呼已更新");naming=null},enabled=!busy){Text("保存")};TextButton(onClick={naming=null}){Text("取消")}}}
        }}
        item(key = "conversations-title") {
            HorizontalDivider()
            Text("录下的对话", Modifier.padding(top=20.dp), style=MaterialTheme.typography.titleLarge)
        }
        if (!loaded) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if (loadFailed) item {
            Text("暂时无法读取录音，正在重试。", color=MaterialTheme.colorScheme.error)
        } else if (loaded && rows.isEmpty() && waitingClips == 0) item {
            Text("还没有录下的对话。", color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (waitingClips > 0) item(key = "waiting-clips") {
            Text("已保存 $waitingClips 段录音，等待识别对话。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        items(rows, key = { "conversation-${it.key}" }) { scene ->
            val sceneRecords = scene.records
            Column {
                Row(Modifier.fillMaxWidth().clickable(enabled=sceneRecords.isNotEmpty()) { expanded=if(expanded==scene.key)null else scene.key }.padding(vertical=12.dp),verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                        Text(date(scene.start,"M 月 d 日 HH:mm")+if(scene.private)" 的私密对话" else " 的对话")
                        Text(if(sceneRecords.isEmpty()) "已保存录音，暂无转写" else "已有 ${sceneRecords.size} 段文字",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if(sceneRecords.isNotEmpty()) Icon(if(expanded==scene.key)Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,if(expanded==scene.key)"收起对话" else "展开对话",tint=MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if(expanded==scene.key && sceneRecords.isNotEmpty()) ConversationText(sceneRecords,app,onSelectRecord)
                HorizontalDivider()
            }
        }
    }
}
