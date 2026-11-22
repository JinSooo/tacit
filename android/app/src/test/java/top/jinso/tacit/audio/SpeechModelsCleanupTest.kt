package top.jinso.tacit.audio

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class SpeechModelsCleanupTest {
    @Test fun stageInUseIsNeverTreatedAsAnOrphan() {
        // Reported case: the maintenance worker's SpeechModels deleted a stage while it was being validated,
        // and the native loader crashed with "File doesn't exist".
        val dir = Files.createTempDirectory("speech-stage").toFile()
        try {
            val now = System.currentTimeMillis()
            val model = dir.resolve("sense-voice").apply { mkdirs() }.resolve("model.int8.onnx").apply { writeText("x") }
            dir.setLastModified(now - 3 * 60 * 60 * 1000L)
            dir.resolve("sense-voice").setLastModified(now - 3 * 60 * 60 * 1000L)
            model.setLastModified(now - 5 * 60 * 1000L)
            assertFalse(SpeechModels.abandonedStage(dir, now))
            model.setLastModified(now - 2 * 60 * 60 * 1000L)
            assertTrue(SpeechModels.abandonedStage(dir, now))
        } finally { dir.deleteRecursively() }
    }
}
