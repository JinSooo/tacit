package top.jinso.tacit.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class LegacyFilesTest {
    @get:Rule val temp = TemporaryFolder()

    // 回归：0.3 覆盖安装到 0.4 后，手机上残留约 1 GB 的总结模型和 OCR 数据。
    @Test fun removesOnlyRetiredDirectoriesAndKeepsSpeechAndRecords() {
        val root = temp.newFolder("no_backup")
        File(root, "summary-model").mkdirs(); File(root, "summary-model/qwen2.5-1.5b-q4.gguf").writeText("x")
        File(root, "offline-ocr/tessdata").mkdirs(); File(root, "offline-ocr/tessdata/chi_sim.traineddata").writeText("x")
        File(root, "speech-models/a/sense-voice").mkdirs()
        File(root, "qnn-models/b").mkdirs()
        File(root, "audio").mkdirs()
        File(root, "history.db").writeText("db")

        assertEquals(listOf("summary-model", "offline-ocr"), LegacyFiles.remove(root))
        assertFalse(File(root, "summary-model").exists())
        assertFalse(File(root, "offline-ocr").exists())
        for (kept in listOf("speech-models/a/sense-voice", "qnn-models/b", "audio", "history.db")) assertTrue(kept, File(root, kept).exists())
        assertEquals(emptyList<String>(), LegacyFiles.remove(root))
    }
}
