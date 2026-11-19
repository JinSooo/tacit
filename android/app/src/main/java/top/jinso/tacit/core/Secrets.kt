package top.jinso.tacit.core

import kotlin.math.ln

object Secrets {
    data class Result(val text: String, val count: Int)
    private val patterns = listOf(
        Regex("-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY)-----[\\s\\S]*?(?:-----END \\1-----|\\z)"),
        Regex("\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b"),
        Regex("\\b(?:gh[pors]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\\b"),
        Regex("\\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}"),
        Regex("\\bxox[a-z]-[A-Za-z0-9-]{10,}"),
        Regex("\\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"),
        Regex("\\bAIza[0-9A-Za-z_-]{35}"),
        Regex("\\bglpat-[A-Za-z0-9_-]{20,}"),
        Regex("\\bhf_[A-Za-z0-9]{30,}\\b"),
        Regex("\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]{8,}\\b"),
    )
    fun redact(input: String): Result {
        var count = 0; var text = input
        fun token(): String { count++; return "[已脱敏]" }
        for (pattern in patterns) text = pattern.replace(text) { token() }
        text = Regex("(\\b(?:Bearer|Token)\\s+)[A-Za-z0-9._~+/=-]{16,}", RegexOption.IGNORE_CASE).replace(text) { it.groupValues[1] + token() }
        text = Regex("(\\b[a-z][a-z0-9+.-]*://[^\\s/@:]+:)([^\\s/@]+)(@)", RegexOption.IGNORE_CASE).replace(text) { it.groupValues[1] + token() + "@" }
        text = Regex("([\"']?(?:password|passwd|pwd|token|access_token|refresh_token|api[_-]?key|secret|client_secret)[\"']?\\s*[:=]\\s*)([\"']?)([A-Za-z0-9_+/.=~%!@#$^&*?:-]{16,})\\2", RegexOption.IGNORE_CASE).replace(text) {
            val value = it.groupValues[3]
            val classes = listOf(Regex("[a-z]"), Regex("[A-Z]"), Regex("[0-9]"), Regex("[^A-Za-z0-9]")).count { r -> r.containsMatchIn(value) }
            val entropy = value.groupingBy { c -> c }.eachCount().values.sumOf { n -> val p = n.toDouble() / value.length; -p * ln(p) / ln(2.0) }
            if (classes >= 2 && entropy >= 3.5) it.groupValues[1] + it.groupValues[2] + token() + it.groupValues[2] else it.value
        }
        return Result(text, count)
    }
}
