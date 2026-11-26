package top.jinso.tacit.audio

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Both PCM and the metadata/voiceprint index are authenticated ciphertext before disk I/O.
 *
 * Files are version 2: AES-256-GCM under a random data key, which is itself wrapped by the Keystore key
 * in `data-key.wrap`. One Keystore operation per process instead of one per file: decrypting ~1900 item
 * files through Keystore took ~24 s on a real phone and held [AudioRuntime.lock] the whole time
 * (2026-11-23). Version 1 files (Keystore key directly) still read; small item files are rewritten as
 * version 2 when the index loads, PCM keeps its version until retention deletes it.
 */
internal interface AudioStore {
    val index: JSONObject
    fun clips(): List<JSONObject>
    fun speakers(): List<JSONObject>
    fun transcripts(): List<JSONObject>
    fun exists(id: String): Boolean
    fun pcm(id: String): FloatArray
    fun discard(clipId: String)
    fun prune(days: Int)
    fun save(vararg clips: JSONObject)
    fun commit(clips: Collection<JSONObject> = emptyList(), speakers: Collection<JSONObject> = emptyList())
    fun saveClip(clip: JSONObject)
    fun saveSpeakers(speakers: Collection<JSONObject>)
    fun deleteConversationAudio(conversationId: String)
}

internal class EncryptedAudioStore(context: Context) : AudioStore {
    private val dir = File(context.noBackupFilesDir, "audio").apply { mkdirs() }
    private val keystoreKey: SecretKey by lazy {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        check(ks.containsAlias("tacit.audio.v1") || dir.listFiles().orEmpty().none { it.name.endsWith(".enc") || it.name.endsWith(".bak") || it.name == WRAP }) { "录音密钥不可用，原文件已保留" }
        (ks.getKey("tacit.audio.v1", null) as? SecretKey) ?: KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("tacit.audio.v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    private val dataKey: SecretKey by lazy {
        val wrapped = File(dir, WRAP)
        // Only the main process opens audio stores (the :qnn process runs inference on PCM it is handed), so
        // an in-process lock is enough to mint exactly one key. Android forbids link() in app data.
        synchronized(KEY_CREATION) {
            if (!wrapped.isFile) {
                // A store with version 2 files but no wrapped key cannot decrypt them; never mint a replacement.
                check(dir.listFiles().orEmpty().none { (it.name.endsWith(".enc") || it.name.endsWith(".bak")) && version(it) == 2 }) {
                    "录音密钥不可用，原文件已保留"
                }
                val raw = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
                val temp = File(dir, "$WRAP.${UUID.randomUUID()}.tmp")
                try {
                    temp.outputStream().use { it.write(sealWith(keystoreKey, 1, WRAP, raw)); it.fd.sync() }
                    check(temp.renameTo(wrapped)) { "录音密钥保存失败" }
                } finally { raw.fill(0); temp.delete() }
            }
        }
        val raw = openWith(keystoreKey, wrapped.readBytes(), 1, WRAP)
        try { SecretKeySpec(raw, "AES") } finally { raw.fill(0) }
    }
    private val indexFile = File(dir, "index.enc")
    private var loaded: JSONObject? = null
    /**
     * In memory the index keeps every clip under "clips" and every voice under "speakers". On disk only
     * conversations and transcripts live in index.enc; each clip is `<id>.meta.enc` and each voice is
     * `<id>.speaker.enc`, so a save costs the same no matter how long recording has run.
     */
    override val index: JSONObject get() = loaded ?: load().also { loaded = it; dropUnusedSpeakers() }
    private fun load(): JSONObject {
        val head = if (indexFile.exists() || File(dir, "index.enc.bak").exists()) {
            val plain = read(indexFile, migrate = true)
            try { JSONObject(String(plain, Charsets.UTF_8)) } finally { plain.fill(0) }
        } else JSONObject()
        // Older layouts kept clips and voices inside index.enc. Item files are written before the head,
        // so a crash in between replays the migration.
        val legacyClips = head.optJSONArray("clips")?.objects()?.filter { exists(it.getString("id")) }
        val legacySpeakers = head.optJSONArray("speakers")?.objects()
        legacyClips?.forEach { compactClip(it); writeItem(META, it) }
        legacySpeakers?.forEachIndexed { n, it -> compactVector(it); if (!it.has("order")) it.put("order", n); writeItem(SPEAKER, it) }
        if (legacyClips != null || legacySpeakers != null) writeHead(head)
        val clips = items(META).filter { clip ->
            exists(clip.getString("id")).also { if (!it) removeMeta(clip.getString("id")) }
        }.sortedBy { it.getLong("start") }
        // Orphans only come from a crash between writes, so one scan per load (plus sweep()) is enough.
        removeUnindexedPcm(clips.map { it.getString("id") }.toSet())
        val speakers = items(SPEAKER).sortedWith(compareBy({ it.optLong("order") }, { it.getString("id") }))
        return head.put("clips", JSONArray(clips)).put("speakers", JSONArray(speakers))
    }
    private fun items(suffix: String): List<JSONObject> = checkNotNull(dir.listFiles())
        .filter { it.name.endsWith(suffix) }.map { file ->
            val plain = read(file, migrate = true)
            try { JSONObject(String(plain, Charsets.UTF_8)) } finally { plain.fill(0) }
        }
    /** Persists the head plus the listed clips. Clips that did not change are never rewritten. */
    override fun save(vararg clips: JSONObject) = commit(clips.toList())
    override fun commit(clips: Collection<JSONObject>, speakers: Collection<JSONObject>) {
        writeHead(index)
        clips.forEach { writeItem(META, it) }
        saveSpeakers(speakers)
    }
    override fun saveClip(clip: JSONObject) = writeItem(META, clip)
    override fun saveSpeakers(speakers: Collection<JSONObject>) = speakers.forEach { writeItem(SPEAKER, it) }
    private fun writeHead(source: JSONObject) {
        val names = source.keys().asSequence().filter { it != "clips" && it != "speakers" }.toList().toTypedArray()
        val plain = JSONObject(source, names).toString().toByteArray(Charsets.UTF_8)
        try { write(indexFile, plain) } finally { plain.fill(0) }
    }
    private fun writeItem(suffix: String, item: JSONObject) {
        val plain = item.toString().toByteArray(Charsets.UTF_8)
        try { write(itemFile(item.getString("id"), suffix), plain) } finally { plain.fill(0) }
    }
    private fun compactClip(clip: JSONObject) = clip.optJSONArray("utterances")?.objects()?.forEach(::compactVector)
    private fun compactVector(row: JSONObject) { row.vectorOrNull("vector")?.let { row.putVector("vector", it) } }
    override fun clips(): List<JSONObject> = index.getJSONArray("clips").objects()
    override fun speakers(): List<JSONObject> = index.getJSONArray("speakers").objects()
    override fun transcripts(): List<JSONObject> = index.optJSONArray("transcripts")?.objects().orEmpty()
    fun add(samples: ShortArray, start: Long): String {
        require(samples.isNotEmpty() && samples.size <= SAMPLE_RATE * 30)
        val id = UUID.randomUUID().toString()
        // Load first: the load-time orphan scan must never see this PCM before its metadata exists.
        val clips = index.getJSONArray("clips")
        val bytes = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { bytes.putShort(it) }
        try { write(file(id), bytes.array()) } finally { bytes.array().fill(0) }
        val clip = JSONObject().put("id", id).put("start", start)
            .put("samples", samples.size).put("analyzed", false).put("utterances", JSONArray())
        clips.put(clip)
        writeItem(META, clip)
        return id
    }
    /** A microphone clip without any voice has nothing to keep; remove its audio and metadata right away. */
    override fun discard(clipId: String) = erase(setOf(clipId)) { false }
    override fun pcm(id: String): FloatArray {
        val bytes = read(file(id))
        try {
            require(bytes.size <= SAMPLE_RATE * 31 * 2 && bytes.size % 2 == 0)
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            return FloatArray(bytes.size / 2) { buf.short / 32768f }
        } finally { bytes.fill(0) }
    }
    override fun exists(id: String) = file(id).isFile
    /** Cheap enough for every query: only touches the files of clips that just expired. */
    override fun prune(days: Int) {
        val now = System.currentTimeMillis()
        // An unfinished legacy import has no committed recording.
        val (drop, keep) = clips().partition { it.optBoolean("pendingImport") || AudioPolicy.expired(it.getLong("start"), now, days) }
        if (drop.isEmpty()) return
        // Published text lives in the head, not in retained PCM metadata, so dropping clip files is enough.
        index.put("clips", JSONArray(keep))
        drop.forEach { val id = it.getString("id"); removePcm(id); removeMeta(id) }
        dropUnusedSpeakers()
    }
    /** Deletes PCM and metadata files no clip refers to; scans the whole directory. */
    fun sweep() { removeUnindexedPcm(clips().map { it.getString("id") }.toSet()); dropUnusedSpeakers() }
    /**
     * A voice nobody confirmed is only useful while some retained clip still has it: without audio it can
     * neither be played nor confirmed. "Me", named and ignored voices are user decisions and always stay.
     * Published transcripts keep their own "对方 N" labels, so rendering does not depend on dropped voices.
     */
    private fun dropUnusedSpeakers() {
        val heard = clips().flatMapTo(mutableSetOf()) { clip ->
            clip.optJSONArray("utterances")?.objects().orEmpty().map { it.getString("speaker") }
        }
        val (drop, keep) = speakers().partition {
            !it.optBoolean("me") && !it.optBoolean("ignored") && it.optString("name").isEmpty() && it.getString("id") !in heard
        }
        if (drop.isEmpty()) return
        index.put("speakers", JSONArray(keep))
        drop.forEach { removeAtomic(itemFile(it.getString("id"), SPEAKER)) }
    }
    fun deleteRecord(recordId: String, matchRef: (String) -> Boolean = { false }) {
        val transcriptClips = transcripts().filter { it.getString("recordId") == recordId }
            .map { it.getString("clipId") }.toSet()
        val selected = clips().filter { clip ->
            val id = clip.getString("id")
            id in transcriptClips || matchRef(id) ||
                clip.getJSONArray("utterances").objects().any { it.optString("record") == recordId }
        }.map { it.getString("id") }.toSet()
        erase(selected) { it.getString("recordId") == recordId }
    }

    fun applyRemoteCleanup(days: Int, before: Long?, refs: Set<String>, wireRef: (String) -> String) {
        fun matches(row: JSONObject, clipId: String, conversation: String): Boolean =
            refs.isNotEmpty() && (row.optString(conversation) in refs || wireRef(clipId) in refs)
        val now = System.currentTimeMillis()
        val removed = clips().filter { clip ->
            val start = clip.getLong("start")
            matches(clip, clip.getString("id"), "conversation") ||
                (before != null && start < before) || AudioPolicy.expired(start, now, days)
        }.map { it.getString("id") }.toSet()
        erase(removed) { matches(it, it.getString("clipId"), "conversationId") }
        sweep()
    }

    private fun removeUnindexedPcm(retained: Set<String>) {
        val files = checkNotNull(dir.listFiles())
        files.filter {
            val id = it.name.substringBefore(".pcm.enc", "").ifEmpty { it.name.substringBefore(META, "") }
            id.isNotEmpty() && id !in retained
        }.forEach { check(it.delete()) { "Audio cleanup failed" } }
    }

    /** Removes retained clips of an untranscribed conversation; never deletes published transcripts. */
    override fun deleteConversationAudio(conversationId: String) {
        val hasTranscripts = transcripts().any { it.getString("conversationId") == conversationId }
        val selected = clips().filter { clip ->
            clip.optString("conversation") == conversationId &&
                clip.getJSONArray("utterances").objects().none { it.optString("record").isNotEmpty() }
        }.map { it.getString("id") }.toSet()
        if (selected.isEmpty()) return
        erase(
            clipIds = selected,
            removeConversation = { !hasTranscripts && it.getString("id") == conversationId },
            removeTranscript = { false },
        )
        dropUnusedSpeakers()
    }

    private fun erase(
        clipIds: Set<String>,
        removeConversation: (JSONObject) -> Boolean = { false },
        removeTranscript: (JSONObject) -> Boolean,
    ) {
        val previous = index
        val retainedText = transcripts().filterNot(removeTranscript)
        val existingConversations = previous.optJSONArray("conversations")?.objects()
        val retainedConversations = existingConversations?.filterNot(removeConversation)
        val conversationsChanged = existingConversations != null && retainedConversations != null &&
            retainedConversations.size != existingConversations.size
        if (clipIds.isEmpty() && retainedText.size == transcripts().size && !conversationsChanged) return
        clipIds.forEach(::removePcm)
        // Only top-level arrays are replaced, so a shallow copy is enough to roll back on a failed write.
        val names = previous.keys().asSequence().toList().toTypedArray()
        val updated = JSONObject(previous, names)
            .put("clips", JSONArray(clips().filterNot { it.getString("id") in clipIds }))
            .put("transcripts", JSONArray(retainedText))
        if (retainedConversations != null) updated.put("conversations", JSONArray(retainedConversations))
        loaded = updated
        try { writeHead(index) } catch (error: Exception) {
            loaded = previous
            throw error
        }
        clipIds.forEach(::removeMeta)
    }

    private fun removePcm(id: String) = removeAtomic(file(id))
    private fun removeMeta(id: String) = removeAtomic(itemFile(id, META))
    private fun removeAtomic(target: File) {
        listOf(target, File(target.path + ".bak"), File(target.path + ".new")).forEach {
            if (it.exists()) check(it.delete()) { "Audio cleanup failed" }
        }
    }
    fun clear() {
        // Save durable text/labels first; failed PCM deletion must not erase already saved History metadata.
        val text = JSONArray(transcripts())
        val groups = index.optJSONArray("conversations") ?: JSONArray()
        loaded = JSONObject().put("clips", JSONArray()).put("speakers", JSONArray())
            .put("transcripts", text).put("conversations", groups)
        save()
        dir.listFiles()?.filter { f -> listOf(".pcm.enc", META, SPEAKER).any { f.name.endsWith(it) || f.name.endsWith("$it.bak") } }
            ?.forEach { check(it.delete()) { "Audio cleanup failed" } }
    }
    private fun file(id: String): File {
        require(Regex("[a-f0-9-]{36}").matches(id))
        return File(dir, "$id.pcm.enc")
    }
    private fun itemFile(id: String, suffix: String): File {
        require(Regex("[A-Za-z0-9-]{1,64}").matches(id)) { "Invalid audio item id" }
        return File(dir, "$id$suffix")
    }
    /** Writes an encrypted file exactly as the store does; only for migration tests that need a layout-1 index. */
    @androidx.annotation.VisibleForTesting
    internal fun writeLegacyIndex(plain: ByteArray) { loaded = null; write(indexFile, plain) }
    /** Writes the legacy Keystore-encrypted layout; only for tests that need version 1 files on disk. */
    @androidx.annotation.VisibleForTesting
    internal fun writeVersion1(name: String, plain: ByteArray) { loaded = null; atomicWrite(File(dir, name), sealWith(keystoreKey, 1, name, plain)) }
    @androidx.annotation.VisibleForTesting
    internal fun versionOf(name: String) = version(File(dir, name))
    private fun write(file: File, plain: ByteArray) = atomicWrite(file, sealWith(dataKey, 2, file.name, plain))
    private fun atomicWrite(file: File, sealed: ByteArray) {
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try { stream.write(sealed); atomic.finishWrite(stream) } catch (e: Exception) { atomic.failWrite(stream); throw e }
    }
    private fun read(file: File, migrate: Boolean = false): ByteArray {
        val all = AtomicFile(file).readFully()
        return when (all.firstOrNull()) {
            2.toByte() -> openWith(dataKey, all, 2, file.name)
            1.toByte() -> openWith(keystoreKey, all, 1, file.name).also { plain ->
                // Rewriting costs one in-process encryption; the Keystore decryption above was the slow part.
                if (migrate) write(file, plain)
            }
            else -> throw IllegalArgumentException("Invalid encrypted audio")
        }
    }
    /** Only the first byte: the check runs over every file, PCM included, before the key exists. */
    private fun version(file: File): Int? = runCatching { file.inputStream().use { it.read() }.takeIf { it >= 0 } }.getOrNull()
    private fun sealWith(key: SecretKey, version: Int, name: String, plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(plain)
        return byteArrayOf(version.toByte()) + cipher.iv + encrypted
    }
    private fun openWith(key: SecretKey, all: ByteArray, version: Int, name: String): ByteArray {
        require(all.size >= 29 && all[0] == version.toByte()) { "Invalid encrypted audio" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, all.copyOfRange(1, 13)))
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(all, 13, all.size - 13)
    }
}
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
internal fun JSONArray.vector(): FloatArray = FloatArray(length()) { getDouble(it).toFloat() }
private const val META = ".meta.enc"
private const val SPEAKER = ".speaker.enc"
private const val WRAP = "data-key.wrap"
private val KEY_CREATION = Any()

/** Vectors are stored as base64 little-endian float32: about a quarter of the decimal JSON size and no float formatting. */
internal fun JSONObject.putVector(name: String, vector: FloatArray): JSONObject {
    val bytes = ByteBuffer.allocate(vector.size * 4).order(ByteOrder.LITTLE_ENDIAN)
    vector.forEach { bytes.putFloat(it) }
    return put(name, java.util.Base64.getEncoder().encodeToString(bytes.array()))
}
/** Reads either the compact form or the legacy decimal JSON array. */
internal fun JSONObject.vectorOrNull(name: String): FloatArray? = when (val value = opt(name)) {
    is JSONArray -> value.vector()
    is String -> {
        val buf = ByteBuffer.wrap(java.util.Base64.getDecoder().decode(value)).order(ByteOrder.LITTLE_ENDIAN)
        FloatArray(buf.remaining() / 4) { buf.float }
    }
    else -> null
}
internal fun JSONObject.vectorAt(name: String): FloatArray = requireNotNull(vectorOrNull(name)) { "Missing vector $name" }
