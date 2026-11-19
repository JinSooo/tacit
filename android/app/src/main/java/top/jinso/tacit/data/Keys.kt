package top.jinso.tacit.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Losing a key fails closed. Existing data is never replaced or silently reset. */
class Keys(private val context: Context) {
    fun databaseKey(databaseExists: Boolean): ByteArray {
        val wrapped = File(context.noBackupFilesDir, "vault.key")
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "tacit.database.v1"
        if (wrapped.exists() || File(wrapped.path + ".bak").exists()) {
            check(store.containsAlias(alias)) { "记录库密钥不可用，原文件已保留" }
            val data = AtomicFile(wrapped).readFully()
            require(data.size > 28) { "记录库密钥文件损坏，原文件已保留" }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, store.getKey(alias, null) as SecretKey, GCMParameterSpec(128, data.copyOfRange(0, 12)))
            return cipher.doFinal(data.copyOfRange(12, data.size))
        }
        check(!databaseExists) { "找不到记录库密钥，原文件已保留" }
        val key = if (store.containsAlias(alias)) store.getKey(alias, null) as SecretKey else KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build()); generateKey()
        }
        val raw = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
        val target = AtomicFile(wrapped); val output = target.startWrite()
        try { output.write(cipher.iv + cipher.doFinal(raw)); target.finishWrite(output) }
        catch (error: Exception) { target.failWrite(output); raw.fill(0); throw error }
        return raw
    }
}
