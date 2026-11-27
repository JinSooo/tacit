package top.jinso.tacit.audio

import top.jinso.tacit.i18n.AppLang
import top.jinso.tacit.i18n.TestStrings
import top.jinso.tacit.R
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SpeechModelDownloadTest {
    private val chinese = TestStrings(AppLang.ZH)
    @get:Rule val temp = TemporaryFolder()
    private val bytes = "fixed test model".toByteArray()
    private val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun resource(path: String = "sense-voice/model.int8.onnx") =
        SpeechModelResource(path, "https://models.example/$path", bytes.size.toLong(), hash)
    private class Connection(url: URL, val body: ByteArray, val status: Int = 200,
        val location: String? = null, val length: Long = body.size.toLong(),
        val stream: InputStream? = null, val range: String? = null) : HttpURLConnection(url) {
        var closed = false
        override fun connect() = Unit
        override fun disconnect() { closed = true }
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getContentLengthLong() = length
        override fun getHeaderField(name: String?) = when (name) {
            "Location" -> location
            "Content-Range" -> range
            else -> null
        }
        override fun getInputStream() = stream ?: ByteArrayInputStream(body)
    }
    @Test fun fixedCatalogMatchesSharedContractHashesAndSize() {
        assertEquals(279787350L, SpeechModelCatalog.totalBytes)
        assertEquals(4, SpeechModelCatalog.resources.size)
        val contract = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, "docs/contracts.md") }.first { it.isFile }.readText()
        (SpeechModelCatalog.resources + SpeechModelCatalog.tagging).forEach { resource ->
            (listOf(resource.sha256) + resource.alternates.map { it.second }).forEach { hash ->
                assertTrue("Hash drift: ${resource.path}", contract.lineSequence().any { line -> line.contains(resource.path) && line.contains(hash) })
            }
        }
        SpeechModelCatalog.resources.take(2).forEach {
            val name = File(it.path).name
            assertEquals(listOf(
                "https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-sense-voice-zh-en-ja-ko-yue/resolve/master/$name",
                "${SpeechModelCatalog.mirror}/sense-voice-$name",
                "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/$name",
            ), listOf(it.url) + it.fallbackUrls)
        }
        (SpeechModelCatalog.resources.drop(2) + SpeechModelCatalog.taggingArchive + QnnCatalog.archive).forEach {
            assertTrue("Mirror first: ${it.path}", it.url.startsWith(SpeechModelCatalog.mirror + "/") && it.fallbackUrls.isNotEmpty())
        }
        assertEquals(SpeechModels.tagging, SpeechModelCatalog.tagging.map { it.path })
    }
    @Test fun sortsByMeasuredSpeedAndRetainsFailedSourcesInCatalogOrder() {
        val slow = "https://slow.example/model"
        val fast = "https://fast.example/model"
        val unreachable = "https://offline.example/model"
        val timeout = "https://timeout.example/model"
        val sources = listOf(slow, unreachable, fast, timeout)
        assertEquals(listOf(fast, slow, unreachable, timeout), rankModelSources(sources) {
            assertEquals(sources, it)
            mapOf(fast to 17.0, slow to 1.0)
        })
        assertEquals(sources, rankModelSources(sources) { emptyMap() })
    }

    @Test fun skipsProbingWhenCandidatesShareAHostnameAndKeepsMirrorFirst() {
        val model = SpeechModelCatalog.taggingArchive
        val sources = listOf(model.url) + model.fallbackUrls + "https://GITHUB.COM:444/another/model"
        for (candidates in listOf(sources.take(1), sources)) {
            assertEquals(candidates, rankModelSources(candidates) { error("No probe needed") })
        }
    }

    @Test fun usesMeasuredOrderAndStillFallsBackWhenFastestHashDoesNotMatch() {
        val model = resource().copy(url = "https://slow.example/model",
            fallbackUrls = listOf("https://fast.example/model", "https://failed.example/model"))
        val requested = mutableListOf<String>()
        val stage = SpeechModelDownload(listOf(model), sourceProbes = { _, _, _ ->
            mapOf(model.url to 1.0, model.fallbackUrls.first() to 17.0)
        }) { url ->
            requested += url.host
            when (url.host) {
                "fast.example" -> Connection(url, ByteArray(bytes.size))
                "slow.example" -> Connection(url, bytes, status = 404)
                else -> Connection(url, bytes)
            }
        }.prepare(temp.root, ModelDownloadCancellation()) { _, _ -> }
        assertEquals(listOf("fast.example", "slow.example", "failed.example"), requested)
        assertArrayEquals(bytes, File(stage, model.path).readBytes())
    }

    @Test fun rangeProbesRunInParallelAndFetchOnlyTheSample() {
        val model = resource().copy(url = "https://fallback.example/model",
            fallbackUrls = listOf("https://reachable.example/model"))
        val parallel = CountDownLatch(2)
        val probed = ConcurrentLinkedQueue<String>()
        val downloaded = mutableListOf<String>()
        val stage = SpeechModelDownload(listOf(model)) { url ->
            val reachable = url.host == "reachable.example"
            object : HttpURLConnection(url) {
                override fun connect() = Unit
                override fun disconnect() = Unit
                override fun usingProxy() = false
                override fun getResponseCode(): Int {
                    if (getRequestProperty("Range") == "bytes=0-${bytes.lastIndex}") {
                        probed += url.host
                        parallel.countDown()
                        if (!parallel.await(1, TimeUnit.SECONDS)) return 408
                    } else {
                        downloaded += url.host
                    }
                    return if (reachable) 200 else 404
                }
                override fun getContentLengthLong() = bytes.size.toLong()
                override fun getInputStream() = ByteArrayInputStream(bytes)
            }
        }.prepare(temp.root, ModelDownloadCancellation()) { _, _ -> }
        assertEquals(setOf("reachable.example", "fallback.example"), probed.toSet())
        assertEquals(listOf("reachable.example"), downloaded)
        assertArrayEquals(bytes, File(stage, model.path).readBytes())
    }

    @Test fun taggingInstallUnpacksOnlyVerifiedFilesAndCleansUp() {
        val model = "model bytes".toByteArray(); val labels = "index,mid,display_name".toByteArray()
        fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
        fun archive(vararg files: Pair<String, ByteArray>): ByteArray {
            val out = java.io.ByteArrayOutputStream()
            org.apache.commons.compress.archivers.tar.TarArchiveOutputStream(
                org.apache.commons.compress.compressors.bzip2.BZip2CompressorOutputStream(out)).use { tar ->
                files.forEach { (name, body) ->
                    tar.putArchiveEntry(org.apache.commons.compress.archivers.tar.TarArchiveEntry(name).apply { size = body.size.toLong() })
                    tar.write(body); tar.closeArchiveEntry()
                }
            }
            return out.toByteArray()
        }
        val folder = SpeechModelCatalog.taggingFolder
        val good = archive("$folder/model.int8.onnx" to model, "$folder/class_labels_indices.csv" to labels, "$folder/test_wavs/1.wav" to model)
        // The real catalog fixes sizes and hashes; substitute the synthetic files' values for this run.
        val catalog = SpeechModelCatalog.tagging
        assertEquals(listOf("audio-tagging/model.int8.onnx", "audio-tagging/class_labels_indices.csv"), catalog.map { it.path })
        val dir = temp.newFolder("current")
        File(dir, "0a1b2c3d-0000-4000-8000-00000000abcd").mkdirs() // partial download left by a killed process
        fun install(body: ByteArray) = runCatching {
            installTaggingWith(dir, listOf(catalog[0].copy(bytes = model.size.toLong(), sha256 = sha(model)),
                catalog[1].copy(bytes = labels.size.toLong(), sha256 = sha(labels))),
                SpeechModelDownload(listOf(SpeechModelResource("audio-tagging.tar.bz2", "https://models.example/a", body.size.toLong(), sha(body)))) { Connection(it, body) })
        }
        assertTrue(install(good).isSuccess)
        assertArrayEquals(model, File(dir, "audio-tagging/model.int8.onnx").readBytes())
        assertEquals(listOf("audio-tagging"), dir.list()!!.toList())

        File(dir, "audio-tagging").deleteRecursively()
        assertTrue(install(archive("$folder/model.int8.onnx" to model)).isFailure)
        assertEquals(emptyList<String>(), dir.list()!!.toList())
    }
    // Regression: upstream re-uploaded the speaker model on 2026-11-19 and every new install failed its checksum.
    @Test fun fallsBackToUpstreamAndAcceptsVerifiedAlternateVersion() {
        val reexport = "fixed test model, re-exported".toByteArray()
        fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
        val model = resource().copy(url = "https://mirror.example/m", fallbackUrls = listOf("https://upstream.example/m"),
            alternates = listOf(reexport.size.toLong() to sha(reexport)))
        val requested = mutableListOf<String>()
        val stage = SpeechModelDownload(listOf(model), sourceProbes = { _, _, _ -> emptyMap() }) {
            requested += it.toString()
            if (it.host == "mirror.example") Connection(it, reexport, status = 404) else Connection(it, reexport)
        }.prepare(temp.root, ModelDownloadCancellation()) { _, _ -> }
        assertEquals(listOf("https://mirror.example/m", "https://upstream.example/m"), requested)
        assertArrayEquals(reexport, File(stage, model.path).readBytes())
        stage.deleteRecursively()

        val tampered = "fixed test model, tampered!!!".toByteArray()
        assertEquals(reexport.size, tampered.size)
        val error = failsCleanly(model) { Connection(it, tampered) }
        assertEquals(R.string.model_checksum_failed, (error as SpeechModelProblem).label)
    }
    @Test fun downloadsAllFilesWithMonotonicProgressAndClosesConnections() {
        val resources = listOf(resource(), resource("tokens.txt"))
        val connections = mutableListOf<Connection>()
        val progress = mutableListOf<Long>()
        val stage = SpeechModelDownload(resources) { Connection(it, bytes).also(connections::add) }
            .prepare(temp.root, ModelDownloadCancellation()) { count, _ -> progress += count }
        resources.forEach { assertArrayEquals(bytes, File(stage, it.path).readBytes()) }
        assertEquals(2L * bytes.size, progress.last())
        assertTrue(progress.zipWithNext().all { it.first <= it.second })
        assertTrue(connections.all { it.closed && it.requestMethod == "GET" && !it.doOutput && !it.instanceFollowRedirects })
    }
    private fun failsCleanly(resource: SpeechModelResource = resource(), factory: (URL) -> HttpURLConnection): Throwable {
        val old = File(temp.root, "existing").apply { mkdir(); File(this,"marker").writeText("keep") }
        val failure = runCatching { SpeechModelDownload(listOf(resource), pause = {}, sourceProbes = { _, _, _ -> emptyMap() }, openConnection = factory).prepare(temp.root, ModelDownloadCancellation()) { _, _ -> } }.exceptionOrNull()
        assertNotNull(failure)
        assertEquals(listOf(old), temp.root.listFiles()!!.toList())
        assertEquals("keep", File(old,"marker").readText())
        return failure!!
    }
    @Test fun rejectsHashMismatchAndRemovesPartialStage() {
        val error = failsCleanly(resource().copy(sha256 = "0".repeat(64))) { Connection(it, bytes) }
        assertEquals("模型文件校验未通过，请重新下载", SpeechPreparationState().finished(error).message?.resolve(chinese))
    }
    @Test fun rejectsTruncatedUnknownLengthResponse() {
        assertEquals(R.string.model_download_incomplete, (failsCleanly { Connection(it,bytes.copyOf(3),length = -1) } as SpeechModelProblem).label)
    }
    @Test fun rejectsOversizedUnknownLengthResponse() {
        assertEquals(R.string.model_size_invalid, (failsCleanly { Connection(it,bytes + bytes,length = -1) } as SpeechModelProblem).label)
    }
    @Test fun rejectsWrongContentLengthBeforeReading() {
        failsCleanly { Connection(it,bytes,length = 1234,stream = object : InputStream() {
            override fun read(): Int = throw AssertionError("Must reject headers before body")
        }) }
    }
    @Test fun rejectsHttpErrorsWithoutTryingToLoadTheirBody() {
        val error = failsCleanly { Connection(it, bytes, status = 503) }
        assertEquals("模型下载失败，请稍后重试", SpeechPreparationState().finished(error).message?.resolve(chinese))
    }
    @Test fun permitsHttpsRedirectButRejectsDowngrade() {
        var requests = 0
        val stage = SpeechModelDownload(listOf(resource())) {
            requests++
            if (requests == 1) Connection(it,bytes,302,"https://cdn.example/model") else Connection(it,bytes)
        }.prepare(temp.root,ModelDownloadCancellation()) { _, _ -> }
        assertEquals(2,requests)
        assertTrue(stage.isDirectory)
        stage.deleteRecursively()
        requests = 0
        failsCleanly { requests++; Connection(it,bytes,302,"http://cdn.example/model") }
        assertEquals(1,requests)
    }
    @Test fun limitsRedirectLoops() {
        var requests = 0
        failsCleanly { requests++; Connection(it,bytes,302,"https://cdn.example/model") }
        assertEquals(6, requests)
    }
    @Test fun resumesAfterInterruptedResponseAndRetriesThrottledSource() {
        val waits = mutableListOf<Long>()
        val connections = mutableListOf<Connection>()
        val cut = 5
        val stage = SpeechModelDownload(listOf(resource()), pause = { waits.add(it) }) { url ->
            when (connections.size) {
                0 -> Connection(url, bytes, stream = object : InputStream() {
                    private var offset = 0
                    override fun read(): Int {
                        if (offset == cut) throw IOException("connection lost")
                        return bytes[offset++].toInt()
                    }
                })
                1 -> Connection(url, bytes, status = 429)
                else -> Connection(url, bytes.copyOfRange(cut, bytes.size), status = 206,
                    range = "bytes $cut-${bytes.lastIndex}/${bytes.size}")
            }.also(connections::add)
        }.prepare(temp.root, ModelDownloadCancellation()) { _, _ -> }
        assertEquals(listOf(null, "bytes=$cut-", "bytes=$cut-"), connections.map { it.getRequestProperty("Range") })
        assertEquals(1500L, waits.sum())
        assertArrayEquals(bytes, File(stage, resource().path).readBytes())
    }

    @Test fun serverThatIgnoresRangeRestartsFileWithoutAppendingIt() {
        val connections = mutableListOf<Connection>()
        val stage = SpeechModelDownload(listOf(resource()), pause = {}) { url ->
            (if (connections.isEmpty()) Connection(url, bytes.copyOf(4), length = -1)
            else Connection(url, bytes)).also(connections::add)
        }.prepare(temp.root, ModelDownloadCancellation()) { _, _ -> }
        assertEquals("bytes=4-", connections[1].getRequestProperty("Range"))
        assertArrayEquals(bytes, File(stage, resource().path).readBytes())
    }

    @Test fun disconnectMidDownloadCleansStageAndKeepsCurrent() {
        failsCleanly { Connection(it,bytes,stream = object : InputStream() {
            var first = true
            override fun read(): Int { if (first) { first=false; return 1 }; throw IOException("connection lost") }
        }) }
    }
    @Test fun cancellationDuringDownloadCleansStage() {
        val token = ModelDownloadCancellation()
        val failure = runCatching {
            SpeechModelDownload(listOf(resource())) { Connection(it,bytes) }
                .prepare(temp.root,token) { count, _ -> if (count > 0) token.cancel() }
        }.exceptionOrNull()
        assertTrue(failure is CancellationException)
        assertTrue(temp.root.listFiles()!!.isEmpty())
    }
    @Test fun cancellationBeforeDownloadMakesNoRequest() {
        val token = ModelDownloadCancellation().apply { cancel() }
        val failure = runCatching { SpeechModelDownload(listOf(resource())) { throw AssertionError("No request") }
            .prepare(temp.root,token) { _, _ -> } }.exceptionOrNull()
        assertTrue(failure is CancellationException)
        assertTrue(temp.root.listFiles()!!.isEmpty())
    }
    @Test fun failedNativeValidationNeverReplacesExistingModel() {
        val old = temp.newFolder("old")
        val stage = temp.newFolder("stage")
        var active = old
        val failure = runCatching { activatePreparedSpeechModels(stage,ModelDownloadCancellation(),
            { throw IllegalArgumentException("native graph invalid") }, { active=it }) }.exceptionOrNull()
        assertNotNull(failure)
        assertEquals(old,active)
        assertTrue(old.isDirectory)
        assertFalse(stage.exists())
    }
    @Test fun cancellingWhileNativeLoadFinishesNeverCommits() {
        val stage = temp.newFolder("stage")
        val token = ModelDownloadCancellation()
        val failure = runCatching { activatePreparedSpeechModels(stage,token,
            { token.cancel() }, { throw AssertionError("Cancelled stage must not activate") }) }.exceptionOrNull()
        assertTrue(failure is CancellationException)
        assertFalse(stage.exists())
    }
    @Test fun commitRunsAfterValidationAndCannotBeCancelledAfterwards() {
        val stage = temp.newFolder("stage")
        val token = ModelDownloadCancellation()
        var loaded = false
        var committed = false
        activatePreparedSpeechModels(stage,token,{ loaded=true },{ assertTrue(loaded); committed=true })
        assertTrue(committed)
        assertTrue(stage.exists())
        assertFalse(token.cancel())
    }
    @Test fun failedPointerCommitRemovesStage() {
        val stage = temp.newFolder("stage")
        val failure = runCatching { activatePreparedSpeechModels(stage,ModelDownloadCancellation(),{},
            { throw IOException("disk full") }) }.exceptionOrNull()
        assertTrue(failure is IOException)
        assertFalse(stage.exists())
    }
}
