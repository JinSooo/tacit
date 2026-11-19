package top.jinso.tacit.audio

import org.apache.commons.compress.archivers.tar.*
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorOutputStream
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CancellationException

class QnnArchiveTest {
    private val bytes = "pinned test model".toByteArray()
    private val resource = SpeechModelResource("model.bin","",bytes.size.toLong(),
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)})
    private fun check(entries: List<Pair<String,ByteArray>>, block: (File,File)->Unit) {
        val root=Files.createTempDirectory("tacit-qnn-test").toFile()
        try {
            val archive=File(root,"test.tar.bz2")
            TarArchiveOutputStream(BZip2CompressorOutputStream(archive.outputStream())).use { tar ->
                entries.forEach { (name,content) ->
                    val entry=TarArchiveEntry(name).apply { size=content.size.toLong() }
                    tar.putArchiveEntry(entry);tar.write(content);tar.closeArchiveEntry()
                }
            }
            val out=File(root,"out").apply { mkdirs() };block(archive,out)
        } finally { root.deleteRecursively() }
    }
    @Test fun extractsOnlyPinnedRegularFileAndChecksHash() = check(listOf("${QnnCatalog.folder}/model.bin" to bytes,"../../escape" to bytes)) { archive,out ->
        QnnCatalog.extract(archive,out,ModelDownloadCancellation(),listOf(resource))
        assertArrayEquals(bytes,File(out,"model.bin").readBytes());assertEquals(1,out.listFiles()!!.size)
    }
    @Test fun wrongHashIsRejected() = check(listOf("${QnnCatalog.folder}/model.bin" to bytes.reversedArray())) { archive,out ->
        assertThrows(IllegalArgumentException::class.java) { QnnCatalog.extract(archive,out,ModelDownloadCancellation(),listOf(resource)) }
    }
    @Test fun duplicateAndMissingEntriesAreRejected() {
        val entry="${QnnCatalog.folder}/model.bin" to bytes
        check(listOf(entry,entry)) { archive,out -> assertThrows(IllegalArgumentException::class.java) { QnnCatalog.extract(archive,out,ModelDownloadCancellation(),listOf(resource)) } }
        check(listOf("other/model.bin" to bytes)) { archive,out -> assertThrows(IllegalArgumentException::class.java) { QnnCatalog.extract(archive,out,ModelDownloadCancellation(),listOf(resource)) } }
    }
    @Test fun cancellationBeforeExtractionWritesNothing() = check(listOf("${QnnCatalog.folder}/model.bin" to bytes)) { archive,out ->
        val cancel=ModelDownloadCancellation();cancel.cancel()
        assertThrows(CancellationException::class.java) { QnnCatalog.extract(archive,out,cancel,listOf(resource)) }
        assertEquals(0,out.listFiles()!!.size)
    }
}
