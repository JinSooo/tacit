package top.jinso.tacit.audio

import android.content.ComponentName
import android.os.Build
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class QnnDeviceTest {
    @Test fun packagedServiceAndSocGuardAreReal() {
        // Runtime identity must match the complete API source compiled by prepare-speech.py.
        assertEquals("935e5ded",com.k2fsa.sherpa.onnx.VersionInfo.gitSha1)
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        @Suppress("DEPRECATION") val service=context.packageManager.getServiceInfo(ComponentName(context,QnnService::class.java),0)
        assertFalse(service.exported)
        assertEquals(context.packageName+":qnn",service.processName)
        val supported=Build.VERSION.SDK_INT>=31 && QnnPolicy.supported(Build.SOC_MODEL,Build.SUPPORTED_ABIS.toList())
        assertEquals(supported,QnnCatalog.supported())
        listOf("libQnnHtp.so","libQnnSystem.so","libQnnHtpV75Stub.so","libQnnHtpV75Skel.so").forEach {
            assertTrue("QNN runtime must be extracted: $it",File(context.applicationInfo.nativeLibraryDir,it).isFile)
        }
    }
    @Test fun invalidModelIsRejectedAcrossProcessWithoutStoppingTheApp() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        QnnClient(context,File(context.noBackupFilesDir,"not-a-model")).use { client ->
            assertThrows(Exception::class.java) { client.validate() }
            assertFalse(client.ready)
        }
        assertEquals(context.packageName,android.app.Application.getProcessName())
    }
    @Test fun unsupportedSocKeepsCpuSpeechWorking() {
        assumeTrue("This check is for a non-SM8650 device",!QnnCatalog.supported())
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val cpu=SpeechModels(context).current()
        assumeTrue("Stage the approved CPU models first",cpu!=null)
        val pcm=fixture(context.filesDir)
        val states=mutableListOf<String>()
        AcceleratedSpeechEngine(LocalSpeechEngine(cpu!!),context,File(context.noBackupFilesDir,"qnn-models/not-installed")){states+=it}.use { engine ->
            assertEquals(listOf("使用 CPU"),states)
            val text=engine.transcribe(pcm)
            assertTrue(text.contains("本地")||text.contains("记录"))
        }
        pcm.fill(0f)
    }
    @Test fun sm8650ActuallyExecutesHtpAndRecognizesTailBeyondThirtySeconds() {
        assumeTrue("HTP evidence requires the exact SM8650 phone",QnnCatalog.supported())
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val models=QnnModels(context)
        if(File(context.noBackupFilesDir,"qnn-models/incoming").isDirectory)models.installStaged()
        val model=models.current()
        assumeTrue("Stage the verified SM8650 model.bin and tokens.txt first",model!=null)
        val pcm=fixture(context.filesDir)
        require(pcm.size<QnnPolicy.maxSamples)
        QnnClient(context,model!!).use { client ->
            val start=android.os.SystemClock.elapsedRealtime();client.validate()
            assertTrue("Successful isolated HTP decode required",client.ready)
            val loaded=android.os.SystemClock.elapsedRealtime()
            // First chunk is silent; the only phrase is beyond 30 seconds. Truncation cannot pass this.
            val long=FloatArray(QnnPolicy.maxSamples+pcm.size);pcm.copyInto(long,QnnPolicy.maxSamples)
            try {
                val text=QnnPolicy.transcribe(long){client.transcribe(it)}
                assertTrue("HTP must recognize the tail, without CPU fallback",text.contains("本地")||text.contains("记录"))
                Log.i("TacitQnnTest","HTP loadMs=${loaded-start}, longDecodeMs=${android.os.SystemClock.elapsedRealtime()-loaded}, samples=${long.size}")
            } finally { long.fill(0f) }
        }
        pcm.fill(0f)
    }
    @Test fun qnnProcessDeathFallsBackToCpuWithoutLosingSpeech() {
        assumeTrue("HTP evidence requires the exact SM8650 phone",QnnCatalog.supported())
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val model=QnnModels(context).current()
        val cpu=SpeechModels(context).current()
        assumeTrue("Stage both approved speech models first",model!=null && cpu!=null)
        val pcm=fixture(context.filesDir)
        val states=mutableListOf<String>()
        try {
            AcceleratedSpeechEngine(LocalSpeechEngine(cpu!!),context,model){states+=it}.use { engine ->
                assertFalse("NPU must stay unloaded while the app only analyzes voices",states.contains("NPU 加速已启用"))
                assertTrue(engine.segments(pcm).isNotEmpty())
                assertFalse(states.contains("NPU 加速已启用"))
                val accelerated=engine.transcribe(pcm)
                assertTrue(accelerated,accelerated.contains("本地")||accelerated.contains("记录"))
                assertTrue("First prove HTP loaded",states.contains("NPU 加速已启用"))
                engine.finishTranscription()
                states.clear()
                assertEquals(accelerated,engine.transcribe(pcm))
                assertTrue("A new batch must load HTP again",states.contains("NPU 加速已启用"))
                val manager=context.getSystemService(android.app.ActivityManager::class.java)
                val process=manager.runningAppProcesses.single { it.processName==context.packageName+":qnn" }
                // Same UID, only our disposable inference process. Simulate Android memory reclamation.
                assertNotEquals(android.os.Process.myPid(),process.pid)
                android.os.Process.killProcess(process.pid)
                val text=engine.transcribe(pcm)
                assertTrue(text,text.contains("本地")||text.contains("记录"))
                assertTrue(states.toString(),states.contains("加速中断，使用 CPU"))
            }
        } finally { pcm.fill(0f) }
    }
    private fun fixture(dir: File): FloatArray {
        val file=File(dir,"speech-fixture.pcm")
        assumeTrue("Provide the approved synthetic PCM fixture",file.isFile)
        val bytes=file.readBytes();val buffer=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return try { FloatArray(bytes.size/2){buffer.short/32768f} } finally { bytes.fill(0) }
    }
}
