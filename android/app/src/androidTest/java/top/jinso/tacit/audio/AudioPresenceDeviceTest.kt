package top.jinso.tacit.audio

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * Regression (2026-11-23): a game the user never heard was transcribed and uploaded because 11.7 s of short
 * lines joined voices matching the Mac voiceprint. A conversation now needs 20 s of "me". Isolated store.
 */
@RunWith(AndroidJUnit4::class)
class AudioPresenceDeviceTest {
    @Test fun aFewShortMeMatchesDoNotMakeTheUserPresent() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(base.noBackupFilesDir, "audio-presence-${UUID.randomUUID()}")
        val context = object : ContextWrapper(base) { override fun getNoBackupFilesDir() = root.apply { mkdirs() } }
        try {
            val store = EncryptedAudioStore(context)
            store.index.getJSONArray("speakers")
                .put(JSONObject().put("id", "me").put("me", true).put("segments", 40).put("seconds", 120.0).put("vector", JSONArray(listOf(1f, 0f))))
                .put(JSONObject().put("id", "other").put("segments", 40).put("seconds", 120.0).put("vector", JSONArray(listOf(0f, 1f))))
            fun conversation(name: String, meSeconds: List<Double>): JSONObject {
                val id = store.add(ShortArray(SAMPLE_RATE), System.currentTimeMillis() - 60_000)
                val utterances = JSONArray().put(JSONObject().put("start", 0).put("length", 30 * SAMPLE_RATE).put("speaker", "other"))
                meSeconds.forEach { utterances.put(JSONObject().put("start", 0).put("length", (it * SAMPLE_RATE).toInt()).put("speaker", "me")) }
                return store.clips().single { it.getString("id") == id }.put("conversation", name).put("analyzed", true).put("utterances", utterances)
            }
            val game = conversation("game", listOf(0.8, 1.44, 2.02, 0.93, 3.2, 1.86, 1.47))
            val talk = conversation("talk", listOf(6.0, 8.5, 10.5))
            store.commit(store.clips(), store.speakers())
            val ledger = AudioLedger(store)
            val voice = ledger.meVoice()
            assertFalse(ledger.eligible(game, allowed = true, voice = voice))
            assertTrue(ledger.eligible(talk, allowed = true, voice = voice))
        } finally { root.deleteRecursively() }
    }
}
