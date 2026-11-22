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

/** The first line that says something; a line of only punctuation (recognized noise) is skipped. */
internal fun firstSentence(raw: String): String {
    val body = readableTranscript(raw).lineSequence().map { it.trim().replaceFirst(speakerPrefix, "") }
        .firstOrNull { line -> line.any(Char::isLetterOrDigit) }.orEmpty()
    val ending = body.indexOfFirst { it in "。！？!?…" }
    return if (ending < 0) body else body.take(ending + 1)
}

/** First sentence across a conversation's records in time order. */
internal fun firstSentence(records: List<top.jinso.tacit.core.HistoryRecord>): String =
    records.sortedBy { it.start }.asSequence().map { firstSentence(it.body) }.firstOrNull(String::isNotEmpty).orEmpty()

internal fun retentionLabel(days: Int): String = if (days == 0) "不自动清除" else "$days 天"
