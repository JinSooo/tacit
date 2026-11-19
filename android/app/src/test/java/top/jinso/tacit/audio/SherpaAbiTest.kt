package top.jinso.tacit.audio

import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.QnnConfig
import org.junit.Assert.*
import org.junit.Test

class SherpaAbiTest {
    @Test fun officialConfigDefaultsLinkThroughTheCompleteMatchingApi() {
        // The QNN APK's native code reads these fields even for provider=cpu.
        // Replacing only QnnConfig breaks callers of its Kotlin mask constructor.
        val model = OfflineRecognizerConfig().modelConfig
        listOf(model.transducer.qnnConfig, model.paraformer.qnnConfig, model.whisper.qnnConfig,
            model.moonshine.qnnConfig, model.senseVoice.qnnConfig, model.nemo.qnnConfig,
            model.zipformerCtc.qnnConfig).forEach { config ->
            assertFalse(config.htpPerfMode)
            assertEquals("",config.backendLib)
        }
        assertEquals(Boolean::class.javaPrimitiveType,QnnConfig::class.java.getDeclaredField("htpPerfMode").type)
    }
}
