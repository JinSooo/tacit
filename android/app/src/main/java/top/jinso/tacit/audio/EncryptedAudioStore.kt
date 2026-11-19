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

/** Both PCM and the metadata/voiceprint index are authenticated ciphertext before disk I/O. */
internal class EncryptedAudioStore(context: Context) {
    private val dir = File(context.noBackupFilesDir, "audio").apply { mkdirs() }
    private val key: SecretKey by lazy {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        check(ks.containsAlias("tacit.audio.v1") || dir.listFiles().orEmpty().none { it.name.endsWith(".enc") || it.name.endsWith(".bak") }) { "录音密钥不可用，原文件已保留" }
        (ks.getKey("tacit.audio.v1", null) as? SecretKey) ?: KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("tacit.audio.v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    private val indexFile = File(dir, "index.enc")
    private var loaded: JSONObject? = null
    val index: JSONObject get() = loaded ?: (if (indexFile.exists() || File(dir, "index.enc.bak").exists()) {
        val plain = read(indexFile)
        try { JSONObject(String(plain, Charsets.UTF_8)) } finally { plain.fill(0) }
    } else JSONObject().put("clips", JSONArray()).put("speakers", JSONArray()))
        .also { loaded = it }
    fun save() {
        val plain = index.toString().toByteArray(Charsets.UTF_8)
        try { write(indexFile, plain) } finally { plain.fill(0) }
    }
    fun clips(): List<JSONObject> = index.getJSONArray("clips").objects()
    fun speakers(): List<JSONObject> = index.getJSONArray("speakers").objects()
    fun transcripts(): List<JSONObject> = index.optJSONArray("transcripts")?.objects().orEmpty()
    fun add(samples: ShortArray, start: Long): String {
        require(samples.isNotEmpty() && samples.size <= SAMPLE_RATE * 30)
        val id = UUID.randomUUID().toString()
        val bytes = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { bytes.putShort(it) }
        try { write(file(id), bytes.array()) } finally { bytes.array().fill(0) }
        index.getJSONArray("clips").put(JSONObject().put("id", id).put("start", start)
            .put("samples", samples.size).put("analyzed", false).put("utterances", JSONArray()))
        save()
        return id
    }
    fun pcm(id: String): FloatArray {
        val bytes = read(file(id))
        try {
            require(bytes.size <= SAMPLE_RATE * 31 * 2 && bytes.size % 2 == 0)
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            return FloatArray(bytes.size / 2) { buf.short / 32768f }
        } finally { bytes.fill(0) }
    }
    fun exists(id: String) = file(id).isFile
    fun prune(days: Int) {
        val now = System.currentTimeMillis()
        // An unfinished legacy import has no committed recording.
        val original = clips()
        val keep = original.filterNot { it.optBoolean("pendingImport") || AudioPolicy.expired(it.getLong("start"), now, days) }
        val ids = keep.map { it.getString("id") }.toSet()
        // Remove orphan ciphertext after a process death between clip and index commit too.
        dir.listFiles()?.filter { it.name.endsWith(".pcm.enc") && it.name.removeSuffix(".pcm.enc") !in ids }
            ?.forEach { check(it.delete()) { "Audio cleanup failed" } }
        // Published text lives in a separate encrypted collection, not in retained PCM metadata.
        if (keep.size != original.size) {
            index.put("clips", JSONArray(keep))
            save()
        }
    }
    fun deleteRecord(recordId: String) {
        val keep = clips().filter { clip ->
            val matches = clip.getJSONArray("utterances").objects().any { it.optString("record") == recordId }
            if (matches) removePcm(clip.getString("id"))
            !matches
        }
        index.put("clips", JSONArray(keep))
        index.put("transcripts", JSONArray(transcripts().filterNot { it.getString("recordId") == recordId })); save()
    }
    private fun removePcm(id: String) {
        val pcm = file(id)
        if (pcm.exists()) check(pcm.delete()) { "Audio cleanup failed" }
    }
    fun clear() {
        // Save durable text/labels first; failed PCM deletion must not erase already saved History metadata.
        val text = JSONArray(transcripts())
        val groups = index.optJSONArray("conversations") ?: JSONArray()
        loaded = JSONObject().put("clips", JSONArray()).put("speakers", JSONArray())
            .put("transcripts", text).put("conversations", groups)
        save()
        dir.listFiles()?.filter { it.name.endsWith(".pcm.enc") || it.name.endsWith(".pcm.enc.bak") }
            ?.forEach { check(it.delete()) { "Audio cleanup failed" } }
    }
    private fun file(id: String): File {
        require(Regex("[a-f0-9-]{36}").matches(id))
        return File(dir, "$id.pcm.enc")
    }
    private fun write(file: File, plain: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(file.name.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(plain)
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try {
            stream.write(byteArrayOf(1)); stream.write(cipher.iv); stream.write(encrypted)
            atomic.finishWrite(stream)
        } catch (e: Exception) { atomic.failWrite(stream); throw e }
    }
    private fun read(file: File): ByteArray {
        val all = AtomicFile(file).readFully()
        require(all.size >= 29 && all[0] == 1.toByte()) { "Invalid encrypted audio" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, all.copyOfRange(1, 13)))
        cipher.updateAAD(file.name.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(all, 13, all.size - 13)
    }
}
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
internal fun JSONArray.vector(): FloatArray = FloatArray(length()) { getDouble(it).toFloat() }
