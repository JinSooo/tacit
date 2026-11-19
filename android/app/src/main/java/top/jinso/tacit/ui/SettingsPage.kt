package top.jinso.tacit.ui

import android.Manifest
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon as AndroidIcon
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import top.jinso.tacit.MainActivity
import top.jinso.tacit.TacitApp
import top.jinso.tacit.core.PausePolicy
import top.jinso.tacit.lifecycle.PauseResumeWorker
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.onboarding.*

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun SettingsPage(
    app:TacitApp,
    resumed:Int,
    notify:(String)->Unit,
    initialSource:String? = null,
    onOpenAudio:()->Unit = { notify("请点底部“录音”，在那里检查或手动开始") },
    onDetailTitle: ((String?) -> Unit)? = null,
) {
    var refresh by remember { mutableIntStateOf(0) }
    var selected by rememberSaveable { mutableStateOf(initialSource) }
    var setupStep by rememberSaveable { mutableIntStateOf(-1) }
    var detailFromSetup by rememberSaveable { mutableStateOf(false) }
    var sourceParent by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingPermission by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(initialSource) {
        if (initialSource != null) { selected = initialSource; sourceParent = null; detailFromSetup = false; setupStep = -1 }
    }
    var editingBlacklist by rememberSaveable { mutableStateOf(false) }
    var pauseMenu by remember { mutableStateOf(false) }
    val health = rememberCollectionHealth(app, resumed, refresh)
    val paused = health?.paused ?: app.prefs.paused
    val activity=LocalActivity.current ?: return
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        Sources.refresh(app);refresh++
        val granted = when(pendingPermission) {
            Sources.AUDIO -> activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==android.content.pm.PackageManager.PERMISSION_GRANTED
            "tacit.notifications" -> app.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()
            else -> pendingPermission?.let{Sources.granted(app,it)} == true
        }
        notify(if(granted) "权限已更新，录音仍需手动开始" else "尚未允许权限；如果系统不再询问，可打开应用信息检查")
        pendingPermission = null
    }
    fun appInfo() = openSystemPage(activity, SystemPage.APP, notify)
    fun requestPermissions(source:String, permissions:List<String>) {
        if(!app.prefs.enabled(source)){notify("请先启用这个来源，再决定是否授权");return}
        pendingPermission=source
        permission.launch(permissions.toTypedArray())
    }
    fun requestNotifications() {
        if(Build.VERSION.SDK_INT>=33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED) {
            pendingPermission="tacit.notifications"
            permission.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS))
        } else openSystemPage(activity, SystemPage.NOTIFICATIONS, notify)
    }
    fun backFromDetail() {
        selected = when {
            detailFromSetup -> null
            sourceParent != null -> sourceParent
            else -> SettingsRoutes.parent(selected)
        }
        sourceParent = null
        detailFromSetup = false
    }
    fun openSource(id:String) {
        detailFromSetup=setupStep>=0
        sourceParent=if(selected==SettingsRoutes.SOURCES) SettingsRoutes.SOURCES else null
        selected=id
    }
    BackHandler(selected!=null||editingBlacklist||setupStep>=0){
        when { editingBlacklist -> editingBlacklist=false;selected!=null -> backFromDetail();setupStep>0 -> setupStep--;else -> setupStep=-1 }
    }
    val entry=Sources.descriptors.firstOrNull{it.id==selected}
    val detailTitle = when {
        editingBlacklist -> "不记录的应用"
        selected == Sources.AUDIO -> "麦克风与录音"
        entry != null -> entry.title
        selected != null -> SettingsRoutes.title(selected)
        setupStep >= 0 -> "检查权限与后台"
        else -> null
    }
    val currentTitleCallback by rememberUpdatedState(onDetailTitle)
    LaunchedEffect(detailTitle) { currentTitleCallback?.invoke(detailTitle) }
    DisposableEffect(Unit) { onDispose { currentTitleCallback?.invoke(null) } }
    val scroll = rememberScrollState()
    LaunchedEffect(selected,setupStep,editingBlacklist) { scroll.scrollTo(0) }
    Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(24.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
        if(detailTitle != null) {
            TextButton(onClick={
                when { editingBlacklist -> editingBlacklist=false; selected!=null -> backFromDetail(); else -> setupStep=-1 }
            }) {
                Icon(Icons.Outlined.ArrowBack,null)
                Spacer(Modifier.width(8.dp))
                Text(when {
                    editingBlacklist || selected==SettingsRoutes.RETENTION -> "隐私与存储"
                    detailFromSetup -> "返回引导"
                    sourceParent==SettingsRoutes.SOURCES -> "数据源"
                    else -> "返回设置"
                })
            }
            if(onDetailTitle == null) Text(detailTitle,style=MaterialTheme.typography.titleLarge)
        }
        when {
            editingBlacklist -> AppExclusions(app,resumed,notify)
            selected==SettingsRoutes.SPEECH -> SpeechSettings(app,notify)
            selected==SettingsRoutes.RETENTION -> AudioStorageSettings(app,notify)
            selected==SettingsRoutes.PRIVACY -> {
                SettingsNavigationRow("不记录的应用", "${app.prefs.blockedApps.size} 个应用") {
                    editingBlacklist=true
                }
                SettingsNavigationRow("录音保留与清理", "保留 ${app.prefs.retentionDays} 天") { selected=SettingsRoutes.RETENTION }
                Text("记录和录音加密保存在这台手机，不上传。",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            }
            selected==SettingsRoutes.SHORTCUT -> {
                Text("长按桌面 Tacit 图标，选择“写一条记录”，也可以添加独立的桌面入口。",color=MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick={val manager=app.getSystemService(ShortcutManager::class.java);if(manager.isRequestPinShortcutSupported){val shortcut=ShortcutInfo.Builder(app,"write").setShortLabel("写一条记录").setIcon(AndroidIcon.createWithResource(app,top.jinso.tacit.R.drawable.ic_stat_tacit)).setIntent(Intent(app,MainActivity::class.java).setAction("top.jinso.tacit.WRITE")).build();manager.requestPinShortcut(shortcut,null)}else notify("当前桌面不支持添加，请长按 Tacit 图标使用")}){Text("添加到桌面")}
            }
            selected==SettingsRoutes.BACKGROUND -> {
                health?.let { current ->
                    NotificationSetup(current,::requestNotifications,notify)
                    HorizontalDivider()
                    BackgroundSetup(current,notify)
                } ?: Text("正在检查系统状态",color=MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick={selected=null;setupStep=0}){Text("检查权限与恢复方式")}
            }
            selected==SettingsRoutes.SOURCES -> {
                Sources.descriptors.forEach{source->
                    val state=health?.sources?.firstOrNull{it.id==source.id}
                    val enabled=state?.enabled ?: app.prefs.enabled(source.id)
                    val granted=state?.granted ?: Sources.granted(app,source.id)
                    Row(Modifier.fillMaxWidth().clickable{openSource(source.id)}.padding(vertical=4.dp),verticalAlignment=Alignment.CenterVertically){
                        Column(Modifier.weight(1f)){Text(source.title);Text(if(state!=null)sourceStatus(state,health) else when{!enabled->"未启用";paused->"已暂停";!granted->"需要授权";else->"已启用"},style=MaterialTheme.typography.bodySmall,color=if(enabled&&!granted)MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)}
                        Switch(enabled,{Sources.setEnabled(app,source.id,it);refresh++})
                        Icon(Icons.Outlined.ChevronRight,null,Modifier.padding(start=8.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    HorizontalDivider()
                }
                SettingsNavigationRow("麦克风与录音") { openSource(Sources.AUDIO) }
                TextButton(onClick={selected=null;setupStep=0}){Text("检查权限与采集")}
            }
            selected==Sources.AUDIO -> {
                Text("仅在你主动开始后录音。允许权限不会自动开启麦克风。",color=MaterialTheme.colorScheme.onSurfaceVariant)
                Text(when(health?.microphoneGranted){true->"麦克风权限已允许";false->"麦克风权限尚未允许";null->"正在检查麦克风权限"},color=MaterialTheme.colorScheme.onSurfaceVariant)
                if(health?.microphoneCaptureExpected==true && health.microphoneGranted.not()) TextButton(onClick={requestPermissions(Sources.AUDIO,listOf(Manifest.permission.RECORD_AUDIO))}){Text("请求麦克风权限")}
                if(health?.audioEnabled==true && !health.microphoneCaptureExpected) Text(audioPermissionText(health),color=MaterialTheme.colorScheme.onSurfaceVariant)
                if(health?.audioEnabled==false) Text("尚未启用录音，请在录音页开始。",color=MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick=::appInfo){Text("检查应用权限")}
                TextButton(onClick={openSystemPage(activity,SystemPage.PRIVACY,notify)}){Text("检查系统麦克风访问")}
                TextButton(onClick=onOpenAudio){Text("查看录音")}
            }
            entry!=null -> {
                Text(entry.description,color=MaterialTheme.colorScheme.onSurfaceVariant)
                val sourceHealth=health?.sources?.firstOrNull{it.id==entry.id}
                val enabled=sourceHealth?.enabled ?: app.prefs.enabled(entry.id)
                val granted=sourceHealth?.granted ?: Sources.granted(app,entry.id)
                Row(verticalAlignment=Alignment.CenterVertically) { Text("启用采集",Modifier.weight(1f));Switch(enabled,{Sources.setEnabled(app,entry.id,it);refresh++}) }
                Text(when { !enabled->"已停用";paused->"采集已暂停";!granted->"等待授权";else->app.prefs.status(entry.id)},color=MaterialTheme.colorScheme.onSurfaceVariant)
                HorizontalDivider()
                Text("权限与配置",style=MaterialTheme.typography.titleLarge)
                Text(sourceHealth?.permissionText ?: if (granted) "系统权限已允许" else "尚未允许系统权限",
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (!enabled) Text("启用这个来源后再授权。已有授权不会自行开启采集。", color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = {
                    runCatching { activity.startActivity(Sources.permissionIntent(app, entry.id)) }.onFailure { appInfo() }
                }, enabled = enabled) { Text(if (granted) "检查系统权限" else "前往授权") }
                if (entry.id == Sources.NOTIFICATION) ChatApps(app, resumed, notify)
                TextButton(onClick={Sources.refresh(app);refresh++;notify("已安排检查，结果会显示在采集状态中")},enabled=enabled&&!paused){Text("检查采集")}
                TextButton(onClick=::appInfo){Text("打开应用信息")}
            }
            setupStep>=0 -> {
                Text(when(setupStep){0->"1  允许所需权限";1->"2  检查后台运行";else->"3  开始与恢复"},style=MaterialTheme.typography.titleLarge)
                Text("只需检查你要用的来源。可以随时返回，不影响补写和已有记录。",color=MaterialTheme.colorScheme.onSurfaceVariant)
                health?.let { current ->
                    when(setupStep) {
                        0 -> {
                            PermissionChecklist(current,::openSource,onOpenAudio)
                            HorizontalDivider()
                            NotificationSetup(current,::requestNotifications,notify)
                        }
                        1 -> { NotificationSetup(current,::requestNotifications,notify);HorizontalDivider();BackgroundSetup(current,notify) }
                        else -> CollectionReady(current,::openSource,onOpenAudio)
                    }
                } ?: Text("正在检查系统状态",color=MaterialTheme.colorScheme.onSurfaceVariant)
                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                    if(setupStep>0)TextButton(onClick={setupStep--}){Text("上一步")}
                    Button(onClick={if(setupStep<2)setupStep++ else setupStep=-1}){Text(if(setupStep<2)"下一步" else "返回设置")}
                }
            }
            else -> {
                Row(verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)){Text("采集",style=MaterialTheme.typography.titleLarge);Text(if(paused)if(app.prefs.pauseUntil>0)"暂停至 "+date(app.prefs.pauseUntil,"M 月 d 日 HH:mm") else "已暂停" else "仅记录你开启的来源",color=MaterialTheme.colorScheme.onSurfaceVariant)}
                    Box {TextButton(onClick={if(paused){PauseResumeWorker.change(app,false);refresh++}else pauseMenu=true}){Text(if(paused)"继续" else "暂停")}
                        DropdownMenu(pauseMenu,{pauseMenu=false}){listOf("暂停 1 小时" to System.currentTimeMillis()+3_600_000,"暂停到明天" to PausePolicy.tomorrow(System.currentTimeMillis()),"暂停，手动继续" to 0L).forEach{(label,until)->DropdownMenuItem(text={Text(label)},onClick={PauseResumeWorker.change(app,true,until);pauseMenu=false;refresh++})}}
                    }
                }
                HorizontalDivider()
                Column {
                    SettingsNavigationRow("数据源", "录音、聊天通知、应用使用") { selected=SettingsRoutes.SOURCES }
                    SettingsNavigationRow("语音转写", "识别说话内容与声音") { selected=SettingsRoutes.SPEECH }
                    SettingsNavigationRow("隐私与存储", "不记录的应用、录音保留与清理") { selected=SettingsRoutes.PRIVACY }
                    SettingsNavigationRow("后台运行", "通知、权限与省电设置") { selected=SettingsRoutes.BACKGROUND }
                    SettingsNavigationRow("快捷补写", "添加桌面入口") { selected=SettingsRoutes.SHORTCUT }
                }
                Text("Tacit "+top.jinso.tacit.BuildConfig.VERSION_NAME,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
