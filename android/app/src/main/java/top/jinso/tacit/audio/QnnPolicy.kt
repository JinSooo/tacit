package top.jinso.tacit.audio

internal object QnnPolicy {
    const val maxSamples = 30 * 16000
    fun supported(soc: String, abis: List<String>) = soc.equals("SM8650", ignoreCase = true) && "arm64-v8a" in abis
    fun ranges(count: Int): List<IntRange> {
        require(count >= 0)
        return (0 until count step maxSamples).map { start -> start until minOf(count.toLong(), start.toLong() + maxSamples).toInt() }
    }
    fun transcribe(samples: FloatArray, decode: (FloatArray) -> String): String = ranges(samples.size).map { range ->
        val chunk = samples.copyOfRange(range.first, range.last + 1)
        try { decode(chunk).trim() } finally { chunk.fill(0f) }
    }.filter { it.isNotBlank() }.joinToString(" ")
}
