package top.jinso.tacit.audio

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class SpeechDeviceTest {
    @Test fun loadInstalledModelsAndRecognizeKnownSyntheticFixture() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val models=SpeechModels(context)
        if(File(context.noBackupFilesDir,"speech-models/incoming").isDirectory)models.installStaged()
        val directory=models.current();assumeTrue("Install approved model resources before running this device check",directory!=null)
        val fixture=File(context.filesDir,"speech-fixture.pcm")
        assumeTrue("Provide the synthetic speech fixture",fixture.isFile)
        val bytes=fixture.readBytes();val buffer=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val pcm=FloatArray(bytes.size/2){buffer.short/32768f}
        LocalSpeechEngine(directory!!).use { engine ->
            engine.validate()
            val segments=engine.segments(pcm)
            assertTrue("VAD must detect synthetic speech",segments.isNotEmpty())
            assertTrue(segments.all{it.vector.isNotEmpty()&&it.vector.all{v->v.isFinite()}})
            val text=engine.transcribe(pcm)
            assertTrue("Known phrase should contain 本地 or 记录",text.contains("本地")||text.contains("记录"))
            // Ending a batch releases the model. The next batch must produce the same text.
            assertTrue(engine.transcriberLoaded)
            engine.finishTranscription();assertFalse(engine.transcriberLoaded)
            assertEquals(text,engine.transcribe(pcm))
            engine.finishTranscription()
            // Recreating the ONNX analysis sessions must give the same vectors.
            assertTrue(engine.voiceprintLoaded)
            engine.finishAnalysis();assertFalse(engine.voiceprintLoaded)
            val again=engine.segments(pcm)
            assertEquals(segments.size,again.size)
            segments.zip(again).forEach{(a,b)->assertEquals(a.start,b.start);assertTrue(a.vector.contentEquals(b.vector))}
            // Regression: a 30 s span once grew the voiceprint arena by ~580 MB; chunked embedding stays bounded
            // and still matches the same voice.
            engine.finishAnalysis()
            val before=android.os.Debug.getNativeHeapAllocatedSize()
            val long=FloatArray(SAMPLE_RATE*30){pcm[it%pcm.size]}
            val longVector=requireNotNull(engine.voiceprint(long))
            val grown=(android.os.Debug.getNativeHeapAllocatedSize()-before)/1048576
            assertTrue("voiceprint arena grew $grown MB",grown<150)
            val short=requireNotNull(engine.voiceprint(pcm))
            val similarity=longVector.indices.sumOf{(longVector[it]*short[it]).toDouble()}
            assertTrue("same voice similarity $similarity",similarity>0.8)
            long.fill(0f)
        }
        pcm.fill(0f);bytes.fill(0)
    }
    @Test fun audioIsEncryptedPrunedAndDeletedOnRealFilesystem() {
        val base=InstrumentationRegistry.getInstrumentation().targetContext
        val context=object:ContextWrapper(base){override fun getNoBackupFilesDir()=File(base.noBackupFilesDir,"audio-test-${id}").apply{mkdirs()};val id=UUID.randomUUID()}
        try {
            val store=EncryptedAudioStore(context);val pcm=ShortArray(16000){12345}
            val old=store.add(pcm,System.currentTimeMillis()-8*86400000L)
            val fresh=store.add(pcm,System.currentTimeMillis())
            assertTrue(store.pcm(fresh).all{kotlin.math.abs(it-12345/32768f)<.0001f})
            assertFalse(File(context.noBackupFilesDir,"audio/$fresh.meta.enc").readBytes().toString(Charsets.UTF_8).contains("samples"))
            store.prune(7);assertFalse(store.exists(old));assertTrue(store.exists(fresh))
            store.clips().first().getJSONArray("utterances").put(org.json.JSONObject().put("record","test-record"));store.save()
            store.deleteRecord("test-record");assertFalse(store.exists(fresh));assertTrue(store.clips().isEmpty())
            store.clear();assertTrue(store.speakers().isEmpty())
        }finally{context.noBackupFilesDir.deleteRecursively()}
    }
}
