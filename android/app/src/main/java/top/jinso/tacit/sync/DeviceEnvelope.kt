package top.jinso.tacit.sync

import org.bouncycastle.crypto.AsymmetricCipherKeyPair
import org.bouncycastle.crypto.hpke.HPKE
import org.json.JSONObject
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64

internal const val MAX_ENVELOPE = 8 * 1024 * 1024
internal val deviceIdPattern = Regex("android-[a-z2-7]{8}")
internal val hubIdPattern = Regex("[a-z2-7]{26}")
internal fun ByteArray.base64url(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(this)
internal fun String.decode64(size: Int? = null): ByteArray = Base64.getUrlDecoder().decode(this).also {
    require((size == null || it.size == size) && it.base64url() == this)
}

internal object DeviceEnvelope {
    const val REQUEST_INFO = "tacit-device-v1"
    const val RESPONSE_INFO = "tacit-device-v1/response"
    private val random = SecureRandom()

    private fun suite(mode: Byte) =
        HPKE(mode, HPKE.kem_X25519_SHA256, HPKE.kdf_HKDF_SHA256, HPKE.aead_AES_GCM128)

    fun generate(): AsymmetricCipherKeyPair = suite(HPKE.mode_base).generatePrivateKey()
    fun restore(secret: ByteArray, public: ByteArray): AsymmetricCipherKeyPair =
        suite(HPKE.mode_base).deserializePrivateKey(secret, public)
    fun secret(keys: AsymmetricCipherKeyPair): ByteArray = suite(HPKE.mode_base).serializePrivateKey(keys.private)
    fun public(keys: AsymmetricCipherKeyPair): ByteArray = suite(HPKE.mode_base).serializePublicKey(keys.public)

    data class Request(val json: ByteArray, val nonce: String)
    fun request(device: String?, hub: String, keys: AsymmetricCipherKeyPair, op: String, body: JSONObject): Request {
        val nonce = ByteArray(16).also(random::nextBytes).base64url()
        val plaintext = JSONObject().put("op", op).put("ts", Instant.now().toString())
            .put("nonce", nonce).put("body", body)
        val wire = seal(plaintext.toString(), REQUEST_INFO, device.orEmpty(), hub, keys.takeIf { device != null })
            .put("device", device ?: JSONObject.NULL)
        return Request(wire.toString().toByteArray(), nonce)
    }

    private fun seal(plain: String, info: String, aad: String, recipient: String, sender: AsymmetricCipherKeyPair?): JSONObject {
        val hpke = suite(if (sender == null) HPKE.mode_base else HPKE.mode_auth)
        val pk = hpke.deserializePublicKey(recipient.decode64(32))
        val (ct, enc) = hpke.seal(pk, info.toByteArray(), aad.toByteArray(), plain.toByteArray(), null, null, sender)
        return JSONObject().put("v", 1).put("enc", enc.base64url()).put("ct", ct.base64url())
    }

    fun open(wire: JSONObject, info: String, aad: String, keys: AsymmetricCipherKeyPair, sender: String?): String {
        require(wire.integer("v") == 1L)
        val hpke = suite(if (sender == null) HPKE.mode_base else HPKE.mode_auth)
        return hpke.open(wire.getString("enc").decode64(32), keys, info.toByteArray(), aad.toByteArray(),
            wire.getString("ct").decode64(), null, null,
            sender?.let { hpke.deserializePublicKey(it.decode64(32)) }).toString(Charsets.UTF_8)
    }
}
