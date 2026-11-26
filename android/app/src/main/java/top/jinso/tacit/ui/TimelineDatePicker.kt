package top.jinso.tacit.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import top.jinso.tacit.R
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.UiStrings
import top.jinso.tacit.ui.components.Caption
import top.jinso.tacit.ui.components.TextAction
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

internal data class CalendarDayCell(
    val date: LocalDate?,
    val isToday: Boolean = false,
    val isSelected: Boolean = false,
    val hasContent: Boolean = false,
    val enabled: Boolean = false,
)

internal fun calendarFirstDayOfWeek(lang: AppLang): DayOfWeek =
    if (lang == AppLang.ZH) DayOfWeek.MONDAY else DayOfWeek.SUNDAY

internal fun calendarWeekdayHeaders(lang: AppLang): List<String> {
    val first = calendarFirstDayOfWeek(lang)
    val locale = if (lang == AppLang.ZH) Locale.SIMPLIFIED_CHINESE else Locale.ENGLISH
    val style = if (lang == AppLang.ZH) TextStyle.NARROW else TextStyle.SHORT
    return (0..6).map { offset -> first.plus(offset.toLong()).getDisplayName(style, locale) }
}

internal fun calendarMonthTitle(month: YearMonth, lang: AppLang, strings: UiStrings): String {
    val locale = if (lang == AppLang.ZH) Locale.SIMPLIFIED_CHINESE else Locale.ENGLISH
    return month.format(DateTimeFormatter.ofPattern(strings.text(R.string.month_heading), locale))
}

internal fun canGoToNextMonth(month: YearMonth, today: LocalDate): Boolean =
    month.isBefore(YearMonth.from(today))

internal fun showsReturnToToday(selected: LocalDate, visibleMonth: YearMonth, today: LocalDate): Boolean =
    selected != today || visibleMonth != YearMonth.from(today)

internal fun monthGrid(
    month: YearMonth,
    selected: LocalDate,
    today: LocalDate,
    availableDays: Set<LocalDate>,
    firstDayOfWeek: DayOfWeek,
): List<CalendarDayCell> {
    val leading = (month.atDay(1).dayOfWeek.value - firstDayOfWeek.value + 7) % 7
    val cells = ArrayList<CalendarDayCell>(42)
    repeat(leading) { cells += CalendarDayCell(date = null) }
    for (dayOfMonth in 1..month.lengthOfMonth()) {
        val date = month.atDay(dayOfMonth)
        val enabled = !date.isAfter(today)
        cells += CalendarDayCell(
            date = date,
            isToday = date == today,
            isSelected = date == selected,
            hasContent = enabled && date in availableDays,
            enabled = enabled,
        )
    }
    val trailing = (7 - cells.size % 7) % 7
    repeat(trailing) { cells += CalendarDayCell(date = null) }
    return cells
}

internal fun calendarDayAccessibilityLabel(
    cell: CalendarDayCell,
    lang: AppLang,
    strings: UiStrings,
): String? {
    val date = cell.date ?: return null
    val locale = if (lang == AppLang.ZH) Locale.SIMPLIFIED_CHINESE else Locale.ENGLISH
    val dateText = date.format(DateTimeFormatter.ofPattern(strings.text(R.string.day_heading_year), locale))
    val parts = ArrayList<String>(3)
    parts += dateText
    if (cell.isToday) parts += strings.text(R.string.today)
    if (cell.hasContent) parts += strings.text(R.string.calendar_has_activity)
    val separator = if (lang == AppLang.ZH) "，" else ", "
    return parts.joinToString(separator)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TimelineDatePickerSheet(
    selected: LocalDate,
    today: LocalDate,
    availableDays: Set<LocalDate>,
    onSelect: (LocalDate) -> Unit,
    onDismiss: () -> Unit,
) {
    val format = uiFormat()
    val strings = uiStrings()
    val lang = format.lang
    var visibleMonth by remember(selected) { mutableStateOf(YearMonth.from(selected)) }
    val nextEnabled = canGoToNextMonth(visibleMonth, today)
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val reduceMotion = LocalReduceMotion.current
    val (shiftIn, shiftOut) = with(LocalDensity.current) { 24.dp.roundToPx() to 16.dp.roundToPx() }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        shape = RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp),
        containerColor = tacitColors.paper,
        contentColor = tacitColors.ink,
        dragHandle = { BottomSheetDefaults.DragHandle(color = tacitColors.faint) },
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    calendarMonthTitle(visibleMonth, lang, strings),
                    Modifier.weight(1f).padding(start = 8.dp),
                    style = MaterialTheme.typography.titleLarge,
                    fontFamily = FontFamily.Serif,
                    fontWeight = FontWeight.Normal,
                    color = tacitColors.ink,
                )
                val nextTint by animateColorAsState(
                    if (nextEnabled) tacitColors.muted else tacitColors.faint,
                    Motion.quick(),
                    label = "next-month",
                )
                IconButton(onClick = { visibleMonth = visibleMonth.minusMonths(1) }) {
                    Icon(
                        Icons.AutoMirrored.Outlined.KeyboardArrowLeft,
                        strings.text(R.string.previous_month),
                        tint = tacitColors.muted,
                    )
                }
                IconButton(
                    onClick = { if (nextEnabled) visibleMonth = visibleMonth.plusMonths(1) },
                    enabled = nextEnabled,
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                        strings.text(R.string.next_month),
                        tint = nextTint,
                    )
                }
            }

            Row(Modifier.fillMaxWidth()) {
                calendarWeekdayHeaders(lang).forEach { label ->
                    Text(
                        label,
                        Modifier.weight(1f).padding(vertical = 4.dp),
                        style = MaterialTheme.typography.bodySmall,
                        color = tacitColors.muted,
                        textAlign = TextAlign.Center,
                    )
                }
            }

            AnimatedContent(
                visibleMonth,
                transitionSpec = {
                    dayTransform(
                        later = targetState.isAfter(initialState),
                        shiftIn = shiftIn,
                        shiftOut = shiftOut,
                        reduce = reduceMotion,
                    )
                },
                label = "calendar-month",
            ) { month ->
                val cells = remember(month, selected, today, availableDays, lang) {
                    monthGrid(month, selected, today, availableDays, calendarFirstDayOfWeek(lang))
                }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    cells.chunked(7).forEach { week ->
                        Row(Modifier.fillMaxWidth()) {
                            week.forEach { cell ->
                                CalendarDaySlot(
                                    cell = cell,
                                    dayDescription = calendarDayAccessibilityLabel(cell, lang, strings),
                                    onSelect = onSelect,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
            }

            if (showsReturnToToday(selected, visibleMonth, today)) {
                Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.End) {
                    TextAction(
                        strings.text(R.string.return_to_today),
                        onClick = { onSelect(today) },
                        color = tacitColors.accent,
                    )
                }
            }
        }
    }
}

@Composable
private fun CalendarDaySlot(
    cell: CalendarDayCell,
    dayDescription: String?,
    onSelect: (LocalDate) -> Unit,
    modifier: Modifier = Modifier,
) {
    val date = cell.date
    if (date == null) {
        Spacer(modifier.height(48.dp))
        return
    }
    val circleModifier = when {
        cell.isSelected -> Modifier.background(tacitColors.accent, CircleShape)
        cell.isToday -> Modifier.border(1.dp, tacitColors.accent, CircleShape)
        else -> Modifier
    }
    val numberColor = when {
        cell.isSelected -> tacitColors.onAccent
        cell.isToday -> tacitColors.accent
        !cell.enabled -> tacitColors.faint
        else -> tacitColors.ink
    }
    Column(
        modifier = modifier
            .heightIn(min = 48.dp)
            .clip(MaterialTheme.shapes.small)
            .semantics {
                if (dayDescription != null) contentDescription = dayDescription
                selected = cell.isSelected
            }
            .clickable(enabled = cell.enabled, role = Role.Button) { onSelect(date) }
            .padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier.size(32.dp).then(circleModifier),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                date.dayOfMonth.toString(),
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (cell.isSelected || cell.isToday) FontWeight.Medium else FontWeight.Normal,
                color = numberColor,
                textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.height(3.dp))
        Box(Modifier.size(4.dp)) {
            if (cell.hasContent) {
                Box(Modifier.fillMaxSize().background(tacitColors.accent, CircleShape))
            }
        }
    }
}
