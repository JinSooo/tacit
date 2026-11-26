package top.jinso.tacit.i18n

// Include letters with CJK Script_Extensions and a different primary Script.
// The letter check excludes shared punctuation such as U+30FB.
private const val CJK_LETTER = "[\\p{L}&&[\\p{IsHan}\\p{IsHiragana}\\p{IsKatakana}\\p{IsHangul}〆〱〲〳〴〵〼ーｰﾞﾟ]]|〇"
private const val LATIN_ALNUM = "(?:\\p{IsLatin}\\p{M}*|[0-9０-９])+"
private val speechTokens = Regex("($CJK_LETTER)|$LATIN_ALNUM")

internal fun speechUnits(text: String): Int =
    speechTokens.findAll(text).fold(0) { units, token -> units + if (token.groups[1] == null) 2 else 1 }
