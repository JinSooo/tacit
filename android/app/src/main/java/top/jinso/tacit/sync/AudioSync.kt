package top.jinso.tacit.sync

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

internal data class MacVoiceprint(val vector: FloatArray, val threshold: Double)

internal data class AudioSync(
    val retention: Int, val purgeBefore: String?, val deleted: List<String>,
    val policy: JSONObject,
) {
    companion object {
        fun parse(body: JSONObject): AudioSync {
            val days = body.integer("retention_days").also { require(it in 0L..365L) }.toInt()
            val purge = body.optionalString("purge_before")?.also { Instant.parse(it) }
            val deleted = body.getJSONArray("delete_conversations").strings().also { refs ->
                require(refs.all { it.isNotBlank() && it.length <= 512 })
            }
            val voice = body.get("voiceprint")
            if (voice != JSONObject.NULL) {
                require(voice is JSONObject)
                voice.voiceprint()
            }
            return AudioSync(days, purge, deleted, JSONObject().put("retention_days", days).put("voiceprint", voice))
        }
    }

    fun ack(): JSONObject = JSONObject().put("purged_at", purgeBefore).put("deleted", JSONArray(deleted))
}

internal fun JSONObject.voiceprint(): MacVoiceprint {
    val vector = getJSONArray("vector")
    require(vector.length() == 512)
    val values = FloatArray(vector.length()) { (vector.get(it) as Number).toFloat() }
    val threshold = (get("threshold") as Number).toDouble()
    require(values.all { it.isFinite() } && values.any { it != 0f } && threshold in 0.0..1.0)
    return MacVoiceprint(values, threshold)
}
