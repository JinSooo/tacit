package top.jinso.tacit.core

import top.jinso.tacit.R
import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.UiStrings

internal const val SPEAKER_ME = "我"
internal const val SPEAKER_OTHER = "对方"
private const val SPEAKER_OTHERS = "其他人"
private val numberedSpeaker = Regex("^$SPEAKER_OTHER[ 　]*([0-9]+)$")
private val transcriptClockPrefix = Regex("^\\[\\d{2}:\\d{2}:\\d{2}\\]\\s*")
private val cjkEdge = Regex("[\\p{IsHan}\\p{IsHiragana}\\p{IsKatakana}\\p{IsHangul}ー]")
private val filler = Regex("(?i)(?:嗯|啊|呃|额|噢|哦|uh|um|hmm)+")
private val noise = Regex("[\\s\\p{P}\\p{S}]")

internal fun speakerNumber(number: Int) = "$SPEAKER_OTHER $number"

internal fun speakerDisplayName(speaker: String, lang: AppLang, strings: UiStrings): String {
    if (lang == AppLang.ZH) return speaker
    return when (speaker) {
        SPEAKER_ME -> strings.text(R.string.speaker_me)
        SPEAKER_OTHER, SPEAKER_OTHERS -> strings.text(R.string.speaker_others)
        else -> numberedSpeaker.matchEntire(speaker)?.groupValues?.get(1)
            ?.let { strings.text(R.string.speaker_number, it) } ?: speaker
    }
}

private val storedSpeakerPrefix =
    Regex("""(?m)^([ \t]*(?:\[\d{2}:\d{2}:\d{2}\][ \t]*)?)($SPEAKER_ME|$SPEAKER_OTHERS|$SPEAKER_OTHER(?:[ 　]*[0-9]+)?)([:：])""")
private val storedAiMePrefix = Regex("""(?m)^([ \t]*)\[$SPEAKER_ME\](?=\s|$)""")

internal fun localizeTranscriptLines(body: String, lang: AppLang, strings: UiStrings): String {
    if (lang == AppLang.ZH) return body
    val spoken = storedSpeakerPrefix.replace(body) { match ->
        val (prefix, speaker, colon) = match.destructured
        "$prefix${speakerDisplayName(speaker, lang, strings)}$colon"
    }
    return storedAiMePrefix.replace(spoken) { match ->
        "${match.groupValues[1]}[${strings.text(R.string.speaker_me)}]"
    }
}

internal data class TranscriptLine(val speaker: String, val text: String)

internal fun transcriptLine(line: String): TranscriptLine {
    val trimmed = line.trim()
    val payload = trimmed.replaceFirst(transcriptClockPrefix, "")
    val ascii = payload.indexOf(':')
    val fullWidth = payload.indexOf('：')
    val prefix = if (ascii > 0 && (fullWidth < 0 || ascii < fullWidth)) payload.take(ascii).trim() else ""
    val canonical = prefix == SPEAKER_ME || prefix == SPEAKER_OTHER || prefix == SPEAKER_OTHERS || numberedSpeaker.matches(prefix)
    val colon = if (canonical) ascii else fullWidth
    if (colon <= 0) return TranscriptLine("", trimmed)
    val speaker = payload.take(colon).trim()
    return TranscriptLine(speaker, payload.substring(colon + 1).trim())
}

/** Display-only cleanup within one <=30s record. Original text stays available verbatim. */
fun readableTranscript(body: String): String {
    val turns = mutableListOf<TranscriptLine>()
    for (line in body.lineSequence()) {
        if (line.isBlank()) continue
        val turn = transcriptLine(line)
        if (turn.speaker.isEmpty()) {
            turns += turn
            continue
        }
        val compact = turn.text.replace(noise, "")
        if (compact.isEmpty() || filler.matches(compact)) continue
        val previous = turns.lastOrNull()
        if (previous?.speaker == turn.speaker) {
            val last = previous.text.last()
            val left = previous.text.codePoints().toArray().lastOrNull(Character::isLetterOrDigit)
            val right = turn.text.codePoints().toArray().firstOrNull(Character::isLetterOrDigit)
            val cjk = left != null && right != null &&
                cjkEdge.matches(String(Character.toChars(left))) && cjkEdge.matches(String(Character.toChars(right)))
            val separator = when {
                cjk && last in "。！？、，；：!?….,;:" -> ""
                cjk -> "，"
                else -> " "
            }
            turns[turns.lastIndex] = previous.copy(text = previous.text + separator + turn.text)
        } else turns += turn
    }
    return turns.joinToString("\n\n") { (speaker, text) -> if (speaker.isBlank()) text else "$speaker：$text" }
}
