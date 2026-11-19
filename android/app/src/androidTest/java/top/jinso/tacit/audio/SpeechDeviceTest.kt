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
            assertFalse(File(context.noBackupFilesDir,"audio/index.enc").readBytes().toString(Charsets.UTF_8).contains(fresh))
            store.prune(7);assertFalse(store.exists(old));assertTrue(store.exists(fresh))
            store.clips().first().getJSONArray("utterances").put(org.json.JSONObject().put("record","test-record"));store.save()
            store.deleteRecord("test-record");assertFalse(store.exists(fresh));assertTrue(store.clips().isEmpty())
            store.clear();assertTrue(store.speakers().isEmpty())
        }finally{context.noBackupFilesDir.deleteRecursively()}
    }
}
