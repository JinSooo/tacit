package top.jinso.tacit.audio

import org.junit.Assert.*
import org.junit.Test

class QnnPolicyTest {
    @Test fun onlyExactTargetSocCanLoadTheContextBinary() {
        assertTrue(QnnPolicy.supported("SM8650",listOf("arm64-v8a")))
        listOf("", "unknown", "SM8550", "SM8650-AC", "Snapdragon 8 Gen 3").forEach {
            assertFalse(QnnPolicy.supported(it,listOf("arm64-v8a")))
        }
        assertFalse(QnnPolicy.supported("SM8650",listOf("x86_64")))
    }
    @Test fun longRecordingIncludesTailAndEverySampleExactlyOnce() {
        val pcm = FloatArray(16000 * 67 + 3) { it.toFloat() }
        var next = 0
        val chunks = mutableListOf<FloatArray>()
        val text = QnnPolicy.transcribe(pcm) { chunk ->
            assertTrue(chunk.size <= 480000)
            chunk.forEach { assertEquals((next++).toFloat(), it, 0f) }
            chunks += chunk
            "chunk${chunks.size}"
        }
        assertEquals(pcm.size,next)
        assertEquals("chunk1 chunk2 chunk3",text)
        assertTrue(chunks.all { chunk -> chunk.all { it == 0f } })
        assertEquals((pcm.size-1).toFloat(),pcm.last(),0f)
    }
    @Test fun boundaryAndEmptyInputsDoNotLoseOrInventSamples() {
        assertEquals(emptyList<IntRange>(),QnnPolicy.ranges(0))
        assertEquals(listOf(0 until 480000),QnnPolicy.ranges(480000))
        assertEquals(listOf(0 until 480000,480000..480000),QnnPolicy.ranges(480001))
        assertEquals("",QnnPolicy.transcribe(floatArrayOf()) { error("must not decode empty input") })
    }
    @Test fun failedChunkIsErasedAndFailurePropagatesForWholeInputFallback() {
        var retained: FloatArray? = null
        assertThrows(IllegalStateException::class.java) {
            QnnPolicy.transcribe(FloatArray(16000) { 0.5f }) { retained=it;error("driver failed") }
        }
        assertTrue(retained!!.all { it == 0f })
    }
}
