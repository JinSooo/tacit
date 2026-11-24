package top.jinso.tacit.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class AudioPageReadTest {
    @Test fun eventuallyDisplaysRecordsWithoutAnotherChangeNotification() = runBlocking {
        val waits = mutableListOf<Long>()
        var failures = 0
        val result = retryAudioPageRead(onFailure = { failures++ }, wait = { waits += it }) {
            if (failures < 7) throw IOException("Test: database unavailable")
            listOf("虚构录音")
        }
        assertEquals(listOf("虚构录音"), result)
        assertEquals(listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 30_000L, 30_000L), waits)
    }

    @Test fun leavingThePageCancelsReadWithoutReportingAFailure() {
        assertThrows(CancellationException::class.java) {
            runBlocking {
                retryAudioPageRead(onFailure = { fail("Cancellation appeared as a load failure") }) {
                    throw CancellationException()
                }
            }
        }
    }
}
