package top.jinso.tacit.ui

import top.jinso.tacit.R
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.UiStrings
import top.jinso.tacit.i18n.speechUnits
import top.jinso.tacit.core.HistoryRecord
import top.jinso.tacit.core.readableTranscript
import top.jinso.tacit.core.SPEAKER_ME
import top.jinso.tacit.core.transcriptLine
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.data.MAX_AUDIO_RETENTION_DAYS
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal fun countLabel(n: Int): String = NumberFormat.getIntegerInstance(Locale.US).format(n)

internal class UiFormat(private val strings: UiStrings, val lang: AppLang, private val use24Hour: Boolean) {
    private val locale = if (lang == AppLang.ZH) Locale.SIMPLIFIED_CHINESE else Locale.ENGLISH
    val timeColumnWidth get() = if (lang == AppLang.EN && !use24Hour) 76 else 56

    private fun date(time: Long, pattern: String): String = Instant.ofEpochMilli(time)
        .atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern(pattern, locale))

    fun clock(time: Long, seconds: Boolean = false): String = date(time, when {
        lang == AppLang.ZH || use24Hour -> if (seconds) "HH:mm:ss" else "HH:mm"
        else -> if (seconds) "h:mm:ss a" else "h:mm a"
    })

    fun calendarDate(time: Long, year: Boolean): String =
        date(time, strings.text(if (year) R.string.date_with_year else R.string.date_without_year))

    fun dateAndClock(time: Long, year: Boolean = false): String =
        strings.text(R.string.date_and_time, calendarDate(time, year), clock(time))

    fun detailTimeLabel(start: Long, end: Long?, includeYear: Boolean): String {
        val startLabel = dateAndClock(start, includeYear)
        if (end == null) return startLabel
        val endLabel = when {
            date(start, "yyyy-MM-dd HH:mm") == date(end, "yyyy-MM-dd HH:mm") -> ""
            date(start, "yyyy-MM-dd") != date(end, "yyyy-MM-dd") ->
                "–" + dateAndClock(end, includeYear || date(start, "yyyy") != date(end, "yyyy"))
            else -> "–" + clock(end)
        }
        return "$startLabel$endLabel · ${durationLabel(end - start)}"
    }

    fun timeRangeLabel(start: Long, end: Long): String {
        val safeEnd = end.coerceAtLeast(start)
        return when {
            date(start, "yyyy-MM-dd HH:mm") == date(safeEnd, "yyyy-MM-dd HH:mm") -> clock(start)
            date(start, "yyyy-MM-dd") != date(safeEnd, "yyyy-MM-dd") -> {
                val includeYear = date(start, "yyyy") != date(safeEnd, "yyyy")
                "${dateAndClock(start, includeYear)}–${dateAndClock(safeEnd, includeYear)}"
            }
            else -> "${clock(start)}–${clock(safeEnd)}"
        }
    }

    internal fun sourceName(source: String): String = strings.text(when (source) {
        "mac.audio" -> R.string.source_conversation
        "mac.screen" -> R.string.source_screen
        "mac.app" -> R.string.source_app
        "mac.clipboard" -> R.string.source_clipboard
        "mac.file" -> R.string.source_file
        "mac.calendar" -> R.string.source_calendar
        "mac.wechat" -> R.string.source_wechat
        "mac.shell" -> R.string.source_terminal
        "mac.git" -> R.string.source_git
        "mac.browser" -> R.string.source_browser
        "claude_code.session" -> R.string.source_claude_code
        "codex.session" -> R.string.source_codex
        Sources.AUDIO -> R.string.source_phone_recording
        Sources.NOTIFICATION -> R.string.source_phone_chat
        Sources.USAGE -> R.string.source_phone_app
        Sources.NOTE -> R.string.source_note
        Sources.CORRECTION -> R.string.source_correction
        "manual.agent" -> R.string.source_ai_note
        else -> R.string.source_other
    })

    fun lastHeardLabel(time: Long, now: Long = System.currentTimeMillis()): String {
        val zone = ZoneId.systemDefault()
        val day = Instant.ofEpochMilli(time).atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return when (day) {
            today -> strings.text(R.string.today_at, clock(time))
            today.minusDays(1) -> strings.text(R.string.yesterday_at, clock(time))
            else -> calendarDate(time, day.year != today.year)
        }
    }

    fun speakerStatus(speaker: top.jinso.tacit.audio.AudioSpeaker, now: Long = System.currentTimeMillis()): String =
        listOfNotNull(speaker.lastSeen?.let { lastHeardLabel(it, now) }, totalSpeechLabel(speaker.seconds))
            .joinToString(if (lang == AppLang.ZH) " · " else ", ")

    fun totalSpeechLabel(seconds: Double): String =
        if (seconds < 60) strings.text(R.string.duration_short)
        else strings.text(R.string.duration_total, durationLabel((seconds * 1000).toLong()))

    fun durationLabel(millis: Long): String {
        val minutes = millis / 60_000
        fun count(value: Long) = NumberFormat.getIntegerInstance(Locale.US).format(value)
        return when {
            minutes < 1 -> strings.text(R.string.duration_short)
            minutes < 60 -> strings.text(R.string.duration_minutes, count(minutes))
            minutes % 60 == 0L -> strings.text(R.string.duration_hours, count(minutes / 60))
            else -> strings.text(R.string.duration_hours_minutes, count(minutes / 60), count(minutes % 60))
        }
    }

    fun conversationTitle(private: Boolean) =
        strings.text(if (private) R.string.conversation_private else R.string.conversation_untitled)

    fun retentionLabel(days: Int): String = if (days == 0) strings.text(R.string.keep_forever)
        else strings.quantity(R.plurals.duration_days, days, countLabel(days))
}

internal fun hasSpeakerMarkers(source: String): Boolean = when (source) {
    "mac.audio", Sources.AUDIO, "codex.session", "claude_code.session" -> true
    else -> false
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

/**
 * 设置页只管理“我”的声音：已确认的按最近出现排，方便核对新近认错的；已同步 Mac 声纹但本机还没匹配到时
 * 仅展示同步状态；尚未确认时，优先给出最长的可试听候选声音。
 */
internal data class MyVoiceOverview(
    val confirmed: List<top.jinso.tacit.audio.AudioSpeaker>,
    val syncedFromMac: Boolean,
    val candidate: top.jinso.tacit.audio.AudioSpeaker?,
    val skippedCandidateCount: Int = 0,
)

internal fun myVoiceOverview(
    speakers: List<top.jinso.tacit.audio.AudioSpeaker>,
    macVoiceKnown: Boolean,
): MyVoiceOverview {
    val visible = speakers.filterNot { it.ignored }
    val confirmed = visible.filter { it.isMe }.sortedWith(
        compareByDescending<top.jinso.tacit.audio.AudioSpeaker> { it.lastSeen ?: Long.MIN_VALUE }
            .thenByDescending { it.seconds },
    )
    // Prefer unnamed voices first, but still allow pre-upgrade named playable voices as fallback so the user is never locked out.
    val candidate = if (macVoiceKnown || confirmed.isNotEmpty()) null
    else visible.filter { it.name == null && it.sampleAvailable }.maxByOrNull { it.seconds }
        ?: visible.filter { it.sampleAvailable }.maxByOrNull { it.seconds }
    val skippedCandidateCount = if (macVoiceKnown || confirmed.isNotEmpty() || candidate != null) 0
    else speakers.count { it.ignored && it.sampleAvailable }
    return MyVoiceOverview(
        confirmed = confirmed,
        syncedFromMac = macVoiceKnown && confirmed.isEmpty(),
        candidate = candidate,
        skippedCandidateCount = skippedCandidateCount,
    )
}

internal fun conversationDuration(records: List<HistoryRecord>) =
    records.maxOf { it.end ?: it.start } - records.minOf { it.start }

// A period ends a sentence only at whitespace or end of line, so decimals and URLs stay intact.
private val sentences = Regex("""[。！？!?…]+|\.(?=\s|$)""")

private fun sentenceParts(line: String): Sequence<String> = sequence {
    var start = 0
    for (end in sentences.findAll(line)) {
        yield(line.substring(start, end.range.last + 1).trim())
        start = end.range.last + 1
    }
    yield(line.substring(start).trim())
}

/** The first line that says something; punctuation-only recognition noise is skipped. */
internal fun firstSentence(raw: String): String = readableTranscript(raw).lineSequence()
    .flatMap { sentenceParts(transcriptLine(it).text) }.firstOrNull { speechUnits(it) > 0 }.orEmpty()

/** Prefer the user's most informative sentence, with the earlier sentence winning ties. */
internal fun telltaleSentence(records: List<HistoryRecord>): String {
    val lines = records.sortedBy { it.start }.asSequence().flatMap { readableTranscript(it.body).lineSequence() }
        .map(::transcriptLine).flatMap { turn ->
            sentenceParts(turn.text).map { Triple(turn.speaker == SPEAKER_ME, it, speechUnits(it)) }
        }.filter { it.third > 0 }.toList()
    fun best(mine: Boolean) = lines.filter { it.first == mine && it.third >= 5 }.maxByOrNull { it.third }?.second
    return best(true) ?: best(false) ?: lines.firstOrNull()?.second.orEmpty()
}

internal fun localRetentionDays(entered: String, keepForever: Boolean): Int? =
    if (keepForever) 0 else entered.toIntOrNull()?.takeIf { it in 1..MAX_AUDIO_RETENTION_DAYS }
