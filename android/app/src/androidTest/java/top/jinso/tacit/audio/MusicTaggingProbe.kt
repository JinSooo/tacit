package top.jinso.tacit.audio

import android.os.Debug
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Read-only calibration on the phone's retained recordings. Prints counts, probabilities, timing and native heap
 * only; never audio, text or speaker ids. Run alone with `am instrument -e class`, never connectedAndroidTest,
 * which would uninstall the app and its data.
 */
@RunWith(AndroidJUnit4::class)
class MusicTaggingProbe {
    /** The voices the phone would ask about: how many of their utterances the detector calls songs. */
    @Test fun classifyCandidateVoices() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val models = SpeechModels(context)
        val dir = models.current()
        assumeTrue(dir != null && !models.taggingMissing())
        val runtime = AudioRuntime.get(context)
        val (speakers, clips) = synchronized(runtime.lock) {
            runtime.store.speakers().filter { !it.optBoolean("me") && it.isNull("name") }
                .sortedByDescending { it.optDouble("seconds") }.take(6)
                .map { it.getString("id") to (it.optBoolean("ignored") to it.optDouble("seconds")) } to
                runtime.store.clips().filter { runtime.store.exists(it.getString("id")) }
        }
        LocalSpeechEngine(dir!!).use { engine ->
            speakers.forEachIndexed { rank, (id, info) ->
                val buckets = IntArray(10); var tagged = 0; var songs = 0; val pairs = StringBuilder()
                loop@ for (clip in clips) {
                    val mine = clip.getJSONArray("utterances").let { a -> (0 until a.length()).map(a::getJSONObject) }
                        .filter { it.optString("speaker") == id }
                    if (mine.isEmpty()) continue
                    val pcm = synchronized(runtime.lock) { runtime.store.pcm(clip.getString("id")) }
                    try {
                        for (u in mine) {
                            if (tagged >= 40) break@loop
                            val from = u.getInt("start"); val to = minOf(pcm.size, from + u.getInt("length"))
                            if (to - from < SAMPLE_RATE / 2) continue
                            val samples = pcm.copyOfRange(from, to)
                            val tags = engine.tags(samples) ?: emptyMap(); samples.fill(0f)
                            val song = listOf(137, 27, 266, 254, 216).maxOf { tags[it] ?: 0f }
                            buckets[minOf(9, (song * 10).toInt())]++; tagged++
                            pairs.append("%.2f/%.2f ".format(song, tags[0] ?: 0f))
                            if (AudioPolicy.music(tags)) songs++
                        }
                    } finally { pcm.fill(0f) }
                }
                Log.i("TacitMusicProbe", "voice#$rank ignored=${info.first} seconds=${info.second.toInt()} " +
                    "tagged=$tagged songs=$songs songProbBuckets=${buckets.joinToString(",")} song/speech=$pairs")
            }
        }
    }

    /** Same replay pressure as the memory acceptance (150 s of segments over retained clips), now with tagging. */
    @Test fun segmentsPeakWithTagging() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val models = SpeechModels(context)
        val dir = models.current()
        assumeTrue(dir != null && !models.taggingMissing())
        val runtime = AudioRuntime.get(context)
        val ids = synchronized(runtime.lock) {
            runtime.store.clips().filter { microphoneClip(it) && runtime.store.exists(it.getString("id")) }.map { it.getString("id") }
        }
        var seconds = 0L; var kept = 0; var peak = 0L; var clips = 0
        val cpu0 = android.os.Process.getElapsedCpuTime(); val began = SystemClock.elapsedRealtime()
        LocalSpeechEngine(dir!!).use { engine ->
            for (id in ids) {
                if (SystemClock.elapsedRealtime() - began > 150_000) break
                val pcm = synchronized(runtime.lock) { runtime.store.pcm(id) }
                try { seconds += pcm.size / SAMPLE_RATE; kept += engine.segments(pcm).onEach { it.samples.fill(0f) }.size } finally { pcm.fill(0f) }
                clips++; peak = maxOf(peak, Debug.getNativeHeapAllocatedSize())
            }
        }
        Log.i("TacitMusicProbe", "replay clips=$clips audioSeconds=$seconds keptSegments=$kept nativePeakMB=${peak / 1_048_576} " +
            "cpuSeconds=${(android.os.Process.getElapsedCpuTime() - cpu0) / 1000} wallSeconds=${(SystemClock.elapsedRealtime() - began) / 1000}")
    }
}
