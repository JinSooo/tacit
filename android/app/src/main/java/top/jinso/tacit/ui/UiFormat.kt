package top.jinso.tacit.ui

import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.core.readableTranscript
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.data.MAX_AUDIO_RETENTION_DAYS
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal fun date(time: Long, pattern: String): String = Instant.ofEpochMilli(time)
    .atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern(pattern, Locale.SIMPLIFIED_CHINESE))

internal fun countLabel(n: Int): String = NumberFormat.getIntegerInstance(Locale.US).format(n)

internal fun detailTimeLabel(start: Long, end: Long?, includeYear: Boolean): String {
    val full = "yyyy 年 M 月 d 日 HH:mm"
    val startLabel = date(start, if (includeYear) full else "M 月 d 日 HH:mm")
    if (end == null) return startLabel
    val endLabel = when {
        date(start, full) == date(end, full) -> ""
        date(start, "yyyy-MM-dd") != date(end, "yyyy-MM-dd") ->
            "–" + date(end, if (includeYear || date(start, "yyyy") != date(end, "yyyy")) full else "M 月 d 日 HH:mm")
        else -> "–" + date(end, "HH:mm")
    }
    return "$startLabel$endLabel · ${durationLabel(end - start)}"
}

internal fun sourceName(source: String): String = when (source) {
    "mac.audio" -> "对话"
    "mac.screen" -> "屏幕"
    "mac.app" -> "应用"
    "mac.clipboard" -> "剪贴板"
    "mac.file" -> "文件"
    "mac.calendar" -> "日历"
    "mac.wechat" -> "微信"
    "mac.shell" -> "终端"
    "mac.git" -> "Git"
    "mac.browser" -> "浏览器"
    "claude_code.session" -> "Claude Code"
    "codex.session" -> "Codex"
    Sources.AUDIO -> "手机录音"
    Sources.NOTIFICATION -> "手机聊天"
    Sources.USAGE -> "手机应用"
    Sources.NOTE -> "补写"
    Sources.CORRECTION -> "修正"
    "manual.agent" -> "AI 补写"
    else -> "其他"
}

// Same lanes the Mac folds when a segment opens: screen, browser and app usage are only the time skeleton.
private val backdropSources = setOf("mac.screen", "mac.app", "mac.browser", Sources.USAGE)

/** Conversations come first and the skeleton folds into one line; a segment of only skeleton lists it plainly. */
internal fun <T> splitBackdrop(items: List<T>, hasOtherMain: Boolean, source: (T) -> String): Pair<List<T>, List<T>> {
    val (backdrop, main) = items.partition { source(it) in backdropSources }
    return if (main.isEmpty() && !hasOtherMain) backdrop to emptyList() else main to backdrop
}

/** Screen-read fragments (12 characters or fewer) join with " · " for display; stored text is unchanged. */
internal fun readingText(text: String, source: String): String {
    if (source != "mac.screen" && source != "mac.browser") return text
    val result = mutableListOf<String>()
    val fragments = mutableListOf<String>()
    fun flush() {
        if (fragments.isEmpty()) return
        result += fragments.joinToString(" · ")
        fragments.clear()
    }
    for (line in text.split(Regex("\\r?\\n"))) {
        val fragment = line.trim()
        if (fragment.isNotEmpty() && fragment.codePointCount(0, fragment.length) <= 12) fragments += fragment
        else { flush(); result += line }
    }
    flush()
    return result.joinToString("\n")
}

internal fun durationLabel(millis: Long): String {
    val minutes = millis / 60_000
    return when {
        minutes < 1 -> "不到 1 分钟"
        minutes < 60 -> "$minutes 分钟"
        minutes % 60 == 0L -> "${minutes / 60} 小时"
        else -> "${minutes / 60} 小时 ${minutes % 60} 分"
    }
}

internal fun conversationDuration(records: List<HistoryRecord>) =
    records.maxOf { it.end ?: it.start } - records.minOf { it.start }

internal fun conversationTitle(private: Boolean) = if (private) "一场私密对话" else "一场对话"

private val speakerPrefix = Regex("^(?:(?:我|对方(?:[ 　]*[0-9]+)?)[：:]|[^：]+：)\\s*")

private fun sentence(line: String): String {
    val ending = line.indexOfFirst { it in "。！？!?…" }
    return if (ending < 0) line else line.take(ending + 1)
}

/** The first line that says something; a line of only punctuation (recognized noise) is skipped. */
internal fun firstSentence(raw: String): String = sentence(readableTranscript(raw).lineSequence()
    .map { it.trim().replaceFirst(speakerPrefix, "") }.firstOrNull { line -> line.any(Char::isLetterOrDigit) }.orEmpty())

/**
 * The line a conversation without a summary shows: the one that says the most, as the Mac timeline drafts do
 * (2026-11-23: the first line was someone else's misrecognized "싫."). The user's own lines first; under 5
 * characters counts as filler; then the longest, the earlier on a tie; someone else's only when the user has none.
 */
internal fun telltaleSentence(records: List<top.jinso.tacit.core.HistoryRecord>): String {
    // A turn joins the speaker's consecutive lines, so every sentence in it is a candidate.
    val lines = records.sortedBy { it.start }.flatMap { readableTranscript(it.body).lines() }.flatMap { raw ->
        val line = raw.trim()
        val mine = Regex("^我[：:]").containsMatchIn(line)
        Regex("[^。！？!?…]+[。！？!?…]*").findAll(line.replaceFirst(speakerPrefix, ""))
            .map { it.value.trim() }.filter { it.any(Char::isLetterOrDigit) }.map { mine to it }.toList()
    }
    fun best(mine: Boolean) = lines.filter { it.first == mine && it.second.count(Char::isLetterOrDigit) >= 5 }
        .maxByOrNull { it.second.count(Char::isLetterOrDigit) }?.second
    return best(true) ?: best(false) ?: lines.firstOrNull()?.second.orEmpty()
}

internal fun retentionLabel(days: Int): String = if (days == 0) "不自动清除" else "$days 天"


internal fun localRetentionDays(entered: String, keepForever: Boolean): Int? =
    if (keepForever) 0 else entered.toIntOrNull()?.takeIf { it in 1..MAX_AUDIO_RETENTION_DAYS }
