package top.jinso.tacit.ui

import android.app.DatePickerDialog
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import top.jinso.tacit.audio.AudioConversation
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.*
import top.jinso.tacit.data.Vault
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.components.*
import top.jinso.tacit.ui.onboarding.CollectionHealth
import java.time.LocalDate
import java.time.ZoneId

@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
internal fun HistoryPage(
    app: TacitApp,
    vault: Vault,
    resumed: Int,
    health: CollectionHealth?,
    synced: String?,
    query: String,
    setQuery: (String) -> Unit,
    onSelect: (HistoryRecord) -> Unit,
    onConversation: (List<HistoryRecord>) -> Unit,
    recovery: @Composable () -> Unit,
) {
    var searching by rememberSaveable { mutableStateOf(false) }
    var filter by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedDay by rememberSaveable { mutableStateOf<String?>(null) }
    fun closeSearch() {
        searching = false
        setQuery("")
        filter = null
    }
    BackHandler(searching) { closeSearch() }

    val activity = LocalActivity.current
    val day = selectedDay?.let(LocalDate::parse)
    val zone = ZoneId.systemDefault()
    val from = day?.atStartOfDay(zone)?.toInstant()?.toEpochMilli()
    val until = day?.plusDays(1)?.atStartOfDay(zone)?.toInstant()?.toEpochMilli()
    var limit by remember(query, filter, selectedDay) { mutableIntStateOf(500) }
    val revision by vault.changes.collectAsState()
    val recordedSources by produceState(emptyList<String>(), vault, revision) {
        value = withContext(Dispatchers.IO) { vault.sources() }
    }
    val scenes by produceState(emptyMap<String, AudioConversation>(), revision, resumed) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                AudioController(app).listConversations().get().flatMap { scene ->
                    scene.recordIds.map { it to scene }
                }.toMap()
            }.getOrDefault(emptyMap())
        }
    }
    val conversations = remember(scenes) { scenes.mapValues { it.value.id } }
    val scope = rememberCoroutineScope()
    fun openConversation(matches: List<HistoryRecord>) {
        val first = matches.first()
        val scene = scenes[first.id]
        if (scene == null || matches.size == scene.recordIds.size) {
            onConversation(matches)
            return
        }
        scope.launch {
            val records = withContext(Dispatchers.IO) {
                scene.recordIds.mapNotNull(vault::get).filter { it.sensitivity == first.sensitivity && it.corrects == null }
            }
            if (records.isNotEmpty()) onConversation(records)
        }
    }
    val records by produceState<List<HistoryRecord>?>(null, vault, query, filter, revision, limit, from, until) {
        value = withContext(Dispatchers.IO) { vault.list(query, filter, limit, from, until) }
    }
    val days = remember(records, conversations, zone) {
        val grouped = groupActivities(records.orEmpty(), conversations).flatMap { group ->
            when (group.first.source) {
                Sources.AUDIO, Sources.USAGE, Sources.NOTIFICATION -> listOf(group)
                else -> group.records.map { ActivityGroup(listOf(it)) }
            }
        }.sortedByDescending { it.timelineStart }
        foldUsageRuns(grouped, zone).groupBy { date(it.timelineStart, "yyyy-MM-dd") }
    }
    val listState = rememberLazyListState()
    LaunchedEffect(query, filter, selectedDay) { listState.scrollToItem(0) }

    Column(Modifier.fillMaxSize()) {
        if (searching) {
            SearchBar(query, setQuery, ::closeSearch)
            Row(
                Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                (listOf(null) + recordedSources).forEach { source ->
                    TimelineChip(source?.let(::sourceName) ?: "全部", filter == source, { filter = source })
                }
            }
        } else {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val paused = health?.paused ?: app.prefs.paused
                val recording = !paused && health?.audioRunning == true
                val status = when {
                    paused && app.prefs.pauseUntil > 0 -> "已暂停到 " + date(app.prefs.pauseUntil, "M 月 d 日 HH:mm")
                    paused -> "已暂停"
                    recording -> "正在录音"
                    enabledSourceCount(app, health) == 0 -> "未在记录"
                    else -> "正在记录"
                }
                FlowRow(
                    Modifier.weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    itemVerticalAlignment = Alignment.CenterVertically,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (recording) Box(Modifier.size(7.dp).background(tacitColors.attention, MaterialTheme.shapes.large))
                        Caption(status, color = if (recording) tacitColors.attention else tacitColors.muted)
                    }
                    if (synced != null) Row(
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Box(Modifier.size(width = 1.dp, height = 12.dp).background(tacitColors.line))
                        Caption(synced)
                    }
                }
                IconButton(onClick = { searching = true }) { Icon(Icons.Outlined.Search, "搜索", tint = tacitColors.ink) }
                IconButton(onClick = {
                    val start = day ?: LocalDate.now()
                    activity?.let {
                        DatePickerDialog(it, { _, year, month, number ->
                            selectedDay = LocalDate.of(year, month + 1, number).toString()
                        }, start.year, start.monthValue - 1, start.dayOfMonth).show()
                    }
                }) { Icon(Icons.Outlined.DateRange, "选择日期", tint = tacitColors.ink) }
            }
        }

        Box(Modifier.padding(horizontal = 16.dp)) { recovery() }

        if (day != null) Box(Modifier.padding(horizontal = 16.dp)) {
            TimelineChip("${day.monthValue} 月 ${day.dayOfMonth} 日", true, { selectedDay = null }, close = true)
        }

        when {
            records == null -> ProgressLine()
            days.isEmpty() -> {
                val filtered = query.isNotBlank() || filter != null || day != null
                EmptyState(
                    if (filtered) "没有匹配的记录" else "今天还没有记录",
                    if (filtered) "换个关键词、日期或来源。" else "开启记录来源，或点右下角写一条。",
                )
            }
            else -> LazyColumn(state = listState, contentPadding = PaddingValues(bottom = 88.dp)) {
                days.forEach { (key, rows) ->
                    stickyHeader(key = "day-$key") { DayHeader(rows.first().timelineStart) }
                    rows.forEach { group ->
                        item(key = group.first.id) { TimelineRow(group, onSelect, ::openConversation) }
                    }
                }
                if (records.orEmpty().size >= limit) item(key = "older") {
                    TonalButton("查看更早的记录", { limit += 500 }, Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
                }
            }
        }
    }
}

@Composable
private fun SearchBar(query: String, update: (String) -> Unit, back: () -> Unit) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = back) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "退出搜索") }
        BasicTextField(
            query, update, Modifier.weight(1f).heightIn(min = 48.dp).focusRequester(focus).padding(end = 16.dp),
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = tacitColors.ink),
            singleLine = true, cursorBrush = SolidColor(tacitColors.ink),
            decorationBox = { field ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (query.isEmpty()) Text("搜索这台手机的记录", color = tacitColors.muted)
                    field()
                }
            },
        )
    }
}

@Composable
private fun TimelineChip(text: String, selected: Boolean, onClick: () -> Unit, close: Boolean = false) {
    FilterChip(
        selected = selected, onClick = onClick, label = { Caption(text, color = tacitColors.ink) },
        trailingIcon = if (close) {{ Icon(Icons.Outlined.Close, "清除日期", Modifier.size(16.dp)) }} else null,
        shape = MaterialTheme.shapes.small,
        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = tacitColors.fill),
    )
}

private val ActivityGroup.timelineStart: Long get() = timelineStart(this)

@Composable
private fun DayHeader(start: Long) {
    Row(
        Modifier.fillMaxWidth().background(tacitColors.paper).padding(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(date(start, "M 月 d 日"), style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Serif)
        Text(date(start, "EEE"), style = MaterialTheme.typography.titleLarge, fontFamily = FontFamily.Serif, color = tacitColors.muted)
    }
}

@Composable
private fun TimelineRow(group: ActivityGroup, onSelect: (HistoryRecord) -> Unit, onConversation: (List<HistoryRecord>) -> Unit) {
    val record = group.first
    val isAudio = record.source == Sources.AUDIO && record.corrects == null
    val isUsage = record.source == Sources.USAGE
    val isChat = record.source == Sources.NOTIFICATION && record.corrects == null
    val isPrimary = isAudio || isChat || record.source in setOf(Sources.NOTE, Sources.CORRECTION)
    val canExpand = isUsage || (isChat && group.records.size > 1)
    val isPrivate = group.records.any { it.sensitivity == "private" }
    var expanded by rememberSaveable { mutableStateOf(false) }
    val title = when {
        isAudio -> "${conversationTitle(isPrivate)}，${durationLabel(conversationDuration(group.records))}"
        else -> record.title
    }
    val preview = remember(group) {
        when {
            isAudio -> firstSentence(group.records.minBy { it.start }.body)
            isPrimary -> record.body
            else -> ""
        }
    }
    val apps = remember(group) { if (isUsage) usageByApp(group.records) else emptyList() }
    val rail = tacitColors.line
    val paper = tacitColors.paper
    val dot = if (isPrimary) tacitColors.accent else tacitColors.faint
    val railModifier = Modifier.drawTimelineRail(rail, paper, dot)
    Column(Modifier.fillMaxWidth().then(railModifier)) {
        Row(
            Modifier.fillMaxWidth()
                .then(if (canExpand) Modifier.semantics { stateDescription = if (expanded) "已展开" else "已收起" } else Modifier)
                .clickable {
                    when {
                        isAudio -> onConversation(group.records)
                        canExpand -> expanded = !expanded
                        else -> onSelect(record)
                    }
                }.padding(start = 20.dp, end = 20.dp, top = 10.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(date(group.timelineStart, "HH:mm"), Modifier.width(40.dp).padding(top = 3.dp), style = MaterialTheme.typography.bodySmall,
                color = tacitColors.muted)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (isUsage) Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("应用使用", Modifier.weight(1f, fill = false), color = tacitColors.muted,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(durationLabel(usageDurationMillis(group.records)), color = tacitColors.muted, softWrap = false)
                    } else Text(title, Modifier.weight(1f), fontWeight = if (isPrimary) FontWeight.Medium else FontWeight.Normal,
                        color = if (isPrimary) tacitColors.ink else tacitColors.muted)
                    if (isUsage) apps.take(3).forEach {
                        SourceIcon(it.record.source, it.record.app, description = it.record.title)
                    } else SourceIcon(record.source, record.app)
                    if (record.corrects != null || record.source == Sources.CORRECTION) Caption("修正")
                    if (isPrivate) PrivacyLock()
                    if (canExpand) Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                        null, Modifier.size(16.dp), tint = tacitColors.muted)
                }
                if (preview.isNotBlank()) Text(preview, color = tacitColors.readingBody, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (isChat && group.records.size > 1) Caption("另外 ${group.records.size - 1} 条")
            }
        }
        if (expanded && isUsage) apps.forEach { usage ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 40.dp).padding(start = 98.dp, end = 20.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SourceIcon(usage.record.source, usage.record.app, description = usage.record.title)
                Text(usage.record.title, Modifier.weight(1f), color = tacitColors.readingBody,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Caption(durationLabel(usage.millis))
            }
        }
        if (expanded && !isUsage) group.records.forEach { part ->
            EvidenceRow(
                time = date(part.start, "HH:mm"),
                text = part.body.ifBlank { part.title },
                private = part.sensitivity == "private",
                modifier = Modifier.padding(start = 98.dp, end = 20.dp),
                onClick = { onSelect(part) },
            )
        }
    }
}

private fun Modifier.drawTimelineRail(rail: androidx.compose.ui.graphics.Color, paper: androidx.compose.ui.graphics.Color,
    dot: androidx.compose.ui.graphics.Color): Modifier = drawBehind {
    val x = if (layoutDirection == androidx.compose.ui.unit.LayoutDirection.Ltr) 79.dp.toPx() else size.width - 79.dp.toPx()
    val center = androidx.compose.ui.geometry.Offset(x, 22.dp.toPx())
    drawLine(rail, androidx.compose.ui.geometry.Offset(x, 0f), androidx.compose.ui.geometry.Offset(x, size.height), 1.dp.toPx())
    drawCircle(paper, 6.5.dp.toPx(), center)
    drawCircle(dot, 3.5.dp.toPx(), center)
}
