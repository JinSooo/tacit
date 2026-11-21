package top.jinso.tacit.audio

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * The first index load decrypts every clip and voice file under [AudioRuntime.lock] and took ~6 s on a
 * real phone; "开始录音" waited on that lock from the main thread and the app hit an ANR. Start/stop and
 * policy changes must only need [AudioRuntime.control]. Touches no recordings or preferences.
 */
@RunWith(AndroidJUnit4::class)
class AudioRuntimeLockDeviceTest {
    @Test fun startStopHandshakeAndPolicyChangesNeverWaitForTheStoreLock() {
        val runtime = AudioRuntime.get(InstrumentationRegistry.getInstrumentation().targetContext)
        val held = CountDownLatch(1); val release = CountDownLatch(1)
        val holder = thread { synchronized(runtime.lock) { held.countDown(); release.await(10, TimeUnit.SECONDS) } }
        try {
            assertTrue(held.await(5, TimeUnit.SECONDS))
            val done = CountDownLatch(1)
            thread { runtime.invalidatePolicy(); synchronized(runtime.control) { runtime.requested }; done.countDown() }
            assertTrue("control path blocked behind the store lock", done.await(1, TimeUnit.SECONDS))
        } finally { release.countDown(); holder.join() }
    }
}
