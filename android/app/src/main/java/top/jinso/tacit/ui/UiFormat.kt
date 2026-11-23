package top.jinso.tacit.ui

import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.core.readableTranscript
import top.jinso.tacit.sources.Sources
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal fun date(time: Long, pattern: String): String = Instant.ofEpochMilli(time)
    .atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern(pattern, Locale.SIMPLIFIED_CHINESE))

internal fun sourceName(source: String): String = when (source) {
    Sources.NOTE -> "补写"
    Sources.CORRECTION -> "修正"
    Sources.AUDIO -> "录音"
    "mac.audio" -> "录音"
    "claude_code.session" -> "Claude Code"
    "codex.session" -> "Codex"
    "mac.wechat" -> "微信"
    "mac.browser" -> "浏览器"
    "mac.screen" -> "屏幕"
    "mac.app" -> "应用"
    // Historical labels for records still visible after an upgrade.
    Sources.NOTIFICATION -> "聊天通知"
    Sources.USAGE -> "应用使用"
    "system.pause" -> "采集状态"
    "android.share" -> "分享"
    "android.screen" -> "屏幕文字"
    "android.sms" -> "短信"
    "android.calls" -> "通话"
    "android.calendar" -> "日历"
    "android.media" -> "照片与截图"
    "android.files" -> "文件"
    "android.location" -> "位置"
    "android.recording_folder" -> "录音目录"
    else -> source
}

internal fun durationLabel(millis: Long): String {
    val minutes = millis / 60_000
    return when {
        minutes < 1 -> "不到 1 分钟"
        minutes < 60 -> "$minutes 分钟"
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
