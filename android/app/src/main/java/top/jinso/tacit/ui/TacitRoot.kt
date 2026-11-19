package top.jinso.tacit.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.core.*
import top.jinso.tacit.data.Vault
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.sources.Sources
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

internal fun date(time:Long,pattern:String) = Instant.ofEpochMilli(time).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern(pattern,java.util.Locale.SIMPLIFIED_CHINESE))
internal fun sourceName(source: String): String = when (source) {
    Sources.NOTE -> "补写"
    Sources.CORRECTION -> "修正"
    Sources.AUDIO -> "录音"
    "system.pause" -> "采集状态"
    // Historical labels for records still visible after an upgrade.
    "android.share" -> "分享"
    "android.screen" -> "屏幕文字"
    "android.sms" -> "短信"
    "android.calls" -> "通话"
    "android.calendar" -> "日历"
    "android.media" -> "照片与截图"
    "android.files" -> "文件"
    "android.location" -> "位置"
    "android.recording_folder" -> "录音目录"
    else -> Sources.descriptors.firstOrNull { it.id == source }?.title ?: source
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun TacitRoot(app:TacitApp,shared:String?,resumed:Int,quickNote:Int,consumeShare:()->Unit) = TacitTheme {
    val scope = rememberCoroutineScope()
    val activity = LocalActivity.current as androidx.lifecycle.ViewModelStoreOwner
    val draftModel = remember(activity) { androidx.lifecycle.ViewModelProvider(activity)[EditorDraftModel::class.java] }
    var vault by remember { mutableStateOf<Vault?>(null) }
    var locked by remember { mutableStateOf(false) }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var settingsSource by remember { mutableStateOf<String?>(null) }
    val collectionHealth = top.jinso.tacit.ui.onboarding.rememberCollectionHealth(app,resumed)
    var editing by rememberSaveable { mutableStateOf(false) }
    var correction by draftModel::correction
    var detail by draftModel::detail
    var initialText by draftModel::initial
    var fromShare by draftModel::sharedOrigin
    val snackbar = remember { SnackbarHostState() }
    fun notify(text:String) { scope.launch { snackbar.showSnackbar(text) } }
    LaunchedEffect(Unit) { try { vault = withContext(Dispatchers.IO) { app.vault } } catch(_:Exception) { locked=true } }
    LaunchedEffect(resumed) { Sources.refresh(app) }
    LaunchedEffect(quickNote) { if(quickNote>0 && !editing) { draftModel.clear(); initialText="";fromShare=false;correction=null;editing=true;detail=null } }
    LaunchedEffect(shared) { if(shared != null) { draftModel.clear(); initialText=shared; fromShare=true; correction=null;editing=true;detail=null;consumeShare() } }
    BackHandler(editing || detail != null) { if(editing) { draftModel.clear();editing=false;correction=null } else detail=null }
    Scaffold(snackbarHost={SnackbarHost(snackbar)},topBar={
        TopAppBar(title={Text(if(editing) if(correction==null) "补写" else "修正记录" else if(detail!=null) "记录详情" else when(tab){0->"历史记录";1->"录音";else->"设置"},style=MaterialTheme.typography.headlineMedium)},navigationIcon={if(editing || detail!=null) IconButton(onClick={draftModel.clear();editing=false;detail=null;correction=null}){Icon(Icons.Outlined.ArrowBack,"返回")}},actions={if(!editing && detail==null && tab==0) Text("Tacit",Modifier.padding(end=24.dp),color=MaterialTheme.colorScheme.onSurfaceVariant)})
    },bottomBar={if(!editing && detail==null) NavigationBar(containerColor=MaterialTheme.colorScheme.surface){listOf("历史" to Icons.Outlined.History,"录音" to Icons.Outlined.MicNone,"设置" to Icons.Outlined.Tune).forEachIndexed { i,p -> NavigationBarItem(selected=tab==i,onClick={tab=i},icon={Icon(p.second,p.first)},label={Text(p.first)})}}},floatingActionButton={if(!locked && vault!=null && tab==0 && !editing && detail==null) FloatingActionButton(onClick={initialText="";fromShare=false;correction=null;editing=true},containerColor=MaterialTheme.colorScheme.primary,contentColor=MaterialTheme.colorScheme.onPrimary){Icon(Icons.Outlined.Add,"补写")}}) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                locked -> Empty("记录库暂时无法打开","密钥或数据库不可用，原文件已保留。请勿卸载应用或清除数据。")
                vault==null -> Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){CircularProgressIndicator()}
                editing -> Editor(initialText,correction,fromShare) { title,body,private ->
                    try { val id=withContext(Dispatchers.IO) { vault!!.ingest(Draft(if(correction == null) Sources.NOTE else Sources.CORRECTION,title,body,method="manual",private=private,corrects=correction?.id)) }; if(id!=null){draftModel.clear();editing=false;detail=null;correction=null;notify("已保存")} }
                    catch(_:Exception){notify("未能保存，请保留输入后重试")}
                }
                detail!=null -> RecordDetail(detail!!,vault!!,onSelect={detail=it},onCorrect={ correction=it;initialText=it.body;fromShare=false;editing=true },onDelete={ record -> scope.launch { try { withContext(Dispatchers.IO){if(record.source==Sources.AUDIO) AudioController(app).deleteRecordAudio(record.id).get();vault!!.delete(record.id)};detail=null;notify("已删除记录及关联修正") } catch(_:Exception){notify("删除未完成，请重试")} } })
                tab==0 -> History(vault!!,onSelect={detail=it},onWrite={initialText="";fromShare=false;editing=true},onSettings={settingsSource=null;tab=2},app=app,resumed=resumed,recovery={collectionHealth?.let { health -> top.jinso.tacit.ui.onboarding.CollectionRecoveryNotice(health,{source->settingsSource=source;tab=2},{tab=1},::notify) }})
                tab==1 -> Column {
                    collectionHealth?.let { health -> Box(Modifier.padding(horizontal=24.dp,vertical=8.dp)) { top.jinso.tacit.ui.onboarding.CollectionRecoveryNotice(health,{source->settingsSource=source;tab=2},{tab=1},::notify) } }
                    AudioPage(app,resumed,::notify)
                }
                else -> SettingsPage(app,resumed,::notify,initialSource=settingsSource,onOpenAudio={tab=1})
            }
        }
    }
}
@Composable private fun Empty(title:String,body:String,action:(@Composable ()->Unit)?=null) {
    Column(Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=48.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) { Text(title,style=MaterialTheme.typography.titleLarge,fontFamily=FontFamily.Serif);Text(body,color=MaterialTheme.colorScheme.onSurfaceVariant);action?.invoke() }
}
@Composable private fun History(vault:Vault,onSelect:(HistoryRecord)->Unit,onWrite:()->Unit,onSettings:()->Unit,app:TacitApp,resumed:Int,recovery:@Composable ()->Unit) {
    var query by remember { mutableStateOf("") };var filter by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedDay by rememberSaveable { mutableStateOf<String?>(null) }
    var sourceMenu by remember { mutableStateOf(false) }
    val activity = LocalActivity.current
    val day = selectedDay?.let{java.time.LocalDate.parse(it)}
    val from = day?.atStartOfDay(ZoneId.systemDefault())?.toInstant()?.toEpochMilli()
    val until = day?.plusDays(1)?.atStartOfDay(ZoneId.systemDefault())?.toInstant()?.toEpochMilli()
    var limit by remember(query,filter,selectedDay){mutableIntStateOf(500)}
    val revision by vault.changes.collectAsState()
    val recordedSources by produceState(emptyList<String>(), vault, revision) {
        value = withContext(Dispatchers.IO) { vault.sources() }
    }
    val conversations by produceState<Map<String,String>>(emptyMap(),revision,resumed) {
        value=withContext(Dispatchers.IO) { runCatching { AudioController(app).listConversations().get().flatMap { scene -> scene.recordIds.map{it to scene.id} }.toMap() }.getOrDefault(emptyMap()) }
    }
    val records by produceState<List<HistoryRecord>>(emptyList(),query,filter,revision,limit,from,until) { value=withContext(Dispatchers.IO){vault.list(query,filter,limit,from,until)} }
    Column { OutlinedTextField(query,{query=it},Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=8.dp),placeholder={Text("搜索这台手机的记录")},leadingIcon={Icon(Icons.Outlined.Search,null)},singleLine=true)
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal=24.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            Box {
                FilterChip(selected=filter!=null,onClick={sourceMenu=true},label={Text(filter?.let(::sourceName)?:"全部来源")},trailingIcon={Icon(Icons.Outlined.ArrowDropDown,null)})
                DropdownMenu(sourceMenu,{sourceMenu=false}) {
                    (listOf(null) + recordedSources).forEach { source ->
                        DropdownMenuItem(text={Text(source?.let(::sourceName)?:"全部来源")},onClick={filter=source;sourceMenu=false})
                    }
                }
            }
            FilterChip(selected=day!=null,onClick={activity?.let{host->val today=day?:java.time.LocalDate.now();android.app.DatePickerDialog(host,{_,year,month,date->selectedDay=java.time.LocalDate.of(year,month+1,date).toString()},today.year,today.monthValue-1,today.dayOfMonth).show()}},label={Text(day?.let{"${it.monthValue} 月 ${it.dayOfMonth} 日"}?:"选择日期")},leadingIcon={Icon(Icons.Outlined.DateRange,null)})
            if(day!=null)TextButton(onClick={selectedDay=null}){Text("全部日期")}
        }
        Box(Modifier.padding(horizontal=24.dp,vertical=8.dp)){recovery()}
        val needsSetup=remember(resumed){Sources.descriptors.none{app.prefs.enabled(it.id)} || Sources.descriptors.any{app.prefs.enabled(it.id)&&!Sources.granted(app,it.id)}}
        if(needsSetup && query.isBlank() && filter==null && day==null) Row(Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=8.dp),verticalAlignment=Alignment.CenterVertically) {
            Text("选择来源并完成授权，开始自动记录。",Modifier.weight(1f),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick=onSettings){Text("设置数据源")}
        }

        if(records.isEmpty()) Empty(if(query.isEmpty()&&filter==null&&day==null) "从今天的一件事开始" else "没有匹配的记录",if(query.isEmpty()&&filter==null&&day==null) "随手补写，或到设置中开启采集。记录只保存在这台手机上。" else "试试其他关键词、日期或来源。",if(query.isEmpty()&&filter==null&&day==null) {{TextButton(onClick=onWrite){Text("写一条记录")}}} else null)
        else LazyColumn(contentPadding=PaddingValues(bottom=96.dp)) {
            var previous=""
            groupActivities(records,conversations).forEach { group ->
                val record=group.first
                val day=date(record.start,"M 月 d 日 EEEE")
                if(day!=previous) {item(key="day-${record.id}"){Text(day,Modifier.padding(start=24.dp,top=24.dp,bottom=12.dp),style=MaterialTheme.typography.titleLarge,fontFamily=FontFamily.Serif)};previous=day}
                item(key=record.id){
                    var expanded by rememberSaveable(record.id){mutableStateOf(false)}
                    Column(Modifier.fillMaxWidth().clickable{if(group.records.size==1)onSelect(record)else expanded=!expanded}.padding(horizontal=24.dp,vertical=16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
                        Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){Text(date(record.start,"HH:mm"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant);Text(sourceName(record.source),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant);if(record.sensitivity=="private") Icon(Icons.Outlined.Lock,"私密",Modifier.size(16.dp));if(record.corrects!=null) Text("修正",style=MaterialTheme.typography.bodySmall)}
                        Text(record.title,style=MaterialTheme.typography.titleMedium)
                        if(record.body.isNotBlank() && record.body!=record.title) Text(record.body,maxLines=2,overflow=TextOverflow.Ellipsis,color=MaterialTheme.colorScheme.onSurfaceVariant)
                        if(group.records.size>1)Text(if(expanded) "收起 ${group.records.size} 段记录" else if(record.source==Sources.AUDIO) "查看整场对话" else "展开 ${group.records.size} 段记录",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.primary)
                    }
                    if(expanded&&record.source==Sources.AUDIO) ConversationText(group.records,app,onSelect)
                    else if(expanded)group.records.forEach{part->Column(Modifier.fillMaxWidth().clickable{onSelect(part)}.padding(start=40.dp,end=24.dp,top=12.dp,bottom=12.dp),verticalArrangement=Arrangement.spacedBy(4.dp)){Text(date(part.start,"HH:mm:ss"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant);Text(part.body.ifBlank{part.title},maxLines=3,overflow=TextOverflow.Ellipsis)}}
                    HorizontalDivider(Modifier.padding(horizontal=24.dp),color=MaterialTheme.colorScheme.outlineVariant)
                }
            }
            if(records.size>=limit)item{TextButton(onClick={limit+=500},modifier=Modifier.padding(24.dp)){Text("查看更早的记录")}}
        }
    }
}
@Composable private fun Editor(initial:String,correct:HistoryRecord?,shared:Boolean,onSave:suspend (String,String,Boolean)->Unit) {
    val activity = LocalActivity.current as? androidx.lifecycle.ViewModelStoreOwner ?: return
    val draft = remember(activity) { androidx.lifecycle.ViewModelProvider(activity)[EditorDraftModel::class.java] }
    LaunchedEffect(correct?.id,initial) { draft.open(correct?.id ?: "new",correct?.title?:"",initial,correct?.sensitivity=="private") }
    var title by draft::title; var body by draft::body; var private by draft::private
    var saving by remember { mutableStateOf(false) };val scope=rememberCoroutineScope()
    Column(Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(20.dp)){
        Text(if(correct!=null) "修正会另存一条，原文仍保留。" else date(System.currentTimeMillis(),"M 月 d 日 HH:mm"),color=MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(title,{title=it.take(200)},Modifier.fillMaxWidth(),label={Text("标题，可留空")},singleLine=true)
        OutlinedTextField(body,{body=it.take(200000);saving=false},Modifier.fillMaxWidth().heightIn(min=200.dp),label={Text(if(shared) "分享内容" else "发生了什么，想记下什么")})
        Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Icon(Icons.Outlined.Lock,null,Modifier.padding(end=12.dp));Text("私密",Modifier.weight(1f));Switch(private,{private=it})}
        Button(onClick={scope.launch {saving=true;try{onSave(title.trim().ifEmpty{body.lineSequence().firstOrNull{it.isNotBlank()}?.take(80)?:"补写"},body,private)}finally{saving=false}}},enabled=body.isNotBlank()&&!saving){Text(if(saving) "保存中" else "保存")}
    }
}
@Composable private fun RecordDetail(record:HistoryRecord,vault:Vault,onSelect:(HistoryRecord)->Unit,onCorrect:(HistoryRecord)->Unit,onDelete:(HistoryRecord)->Unit) {
    var deleting by remember(record.id) {mutableStateOf(false)}
    val changes by vault.changes.collectAsState()
    val corrected by produceState(emptyList<HistoryRecord>(),record.id,changes){value=withContext(Dispatchers.IO){vault.corrections(record.id)}}
    val application = LocalActivity.current!!.application as TacitApp
    val audioController = remember { AudioController(application) }
    val rendered by produceState(record.body,record.id) { if(record.source==Sources.AUDIO)value=withContext(Dispatchers.IO){runCatching{audioController.renderTranscript(record.id,record.body).get()}.getOrDefault(record.body)} }
    val latestCorrection=corrected.maxWithOrNull(compareBy<HistoryRecord>{it.start}.thenBy{it.id})
    val displayBody=latestCorrection?.body?:if(record.source==Sources.AUDIO)readableTranscript(rendered)else rendered
    var raw by remember(record.id){mutableStateOf(false)}
    val original by produceState<HistoryRecord?>(null,record.corrects,changes){value=record.corrects?.let{withContext(Dispatchers.IO){vault.get(it)}}}
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(24.dp)){
        Text(date(record.start,"yyyy 年 M 月 d 日 HH:mm")+"  "+sourceName(record.source),color=MaterialTheme.colorScheme.onSurfaceVariant)
        Text(record.title,style=MaterialTheme.typography.headlineMedium)
        if(record.sensitivity=="private") Text("私密记录",color=MaterialTheme.colorScheme.primary)
        if(displayBody.isBlank())Text("这一段没有需要展示的完整内容，可展开原始转写。",color=MaterialTheme.colorScheme.onSurfaceVariant)else SelectionContainer{Text(displayBody)}
        if(latestCorrection!=null){TextButton(onClick={onSelect(latestCorrection)}){Text("当前显示后续修正，查看这条修正")}}
        if(displayBody!=record.body){TextButton(onClick={raw=!raw}){Text(if(raw)"收起原文" else "查看原文")};if(raw)SelectionContainer{Text(record.body)}}
        original?.let { TextButton(onClick={onSelect(it)}) { Text("查看原记录") } }
        if(corrected.isNotEmpty()) {
            HorizontalDivider()
            Text("后续修正",style=MaterialTheme.typography.titleLarge)
            corrected.asReversed().forEach { change -> Column(Modifier.clickable { onSelect(change) }, verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text("查看 "+date(change.start,"M 月 d 日 HH:mm")+" 的修正",color=MaterialTheme.colorScheme.primary)
            } }
        }
        if(record.redactions>0) Text("已过滤 ${record.redactions} 处凭据",color=MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider();Row{TextButton(onClick={onCorrect(record)}){Text("修正")};Spacer(Modifier.weight(1f));TextButton(onClick={deleting=true}){Text("删除",color=MaterialTheme.colorScheme.error)}}
    }
    if(deleting) AlertDialog(onDismissRequest={deleting=false},title={Text("删除这条记录？")},text={Text("这条记录和关联修正会永久删除，无法恢复。")},confirmButton={TextButton(onClick={deleting=false;onDelete(record)}){Text("删除",color=MaterialTheme.colorScheme.error)}},dismissButton={TextButton(onClick={deleting=false}){Text("取消")}})
}
