package top.jinso.tacit.ui.onboarding

import org.junit.Assert.*
import org.junit.Test

class CollectionHealthTest {
    private val ready = CollectionHealth(
        microphoneGranted = true, audioEnabled = true, audioCaptureWanted = true,
        audioRunning = true, audioStarting = false,
        notificationsEnabled = true, audioChannel = ChannelAccess.ALLOWED,
        batteryExempt = true, backgroundRestricted = false, powerSave = false,
    )

    @Test fun stoppedRecordingDoesNotCountBackgroundProblems() {
        val problems = ready.copy(
            microphoneGranted = false, notificationsEnabled = false, audioChannel = ChannelAccess.BLOCKED,
            batteryExempt = false, backgroundRestricted = true, powerSave = true,
        )
        assertEquals(6, backgroundProblemCount(problems))
        // The preference changes before the service has finished stopping.
        assertEquals(0, backgroundProblemCount(problems.copy(audioCaptureWanted = false)))
        assertEquals(0, backgroundProblemCount(problems.copy(audioEnabled = false)))
        assertEquals(0, backgroundProblemCount(ready))
    }

    @Test fun observedStartingOrRunningCaptureCountsBeforeSavedIntentRefreshes() {
        val running = ready.copy(audioCaptureWanted = false)
        assertTrue(running.microphoneCaptureExpected)
        val starting = running.copy(audioRunning = false, audioStarting = true)
        assertTrue(starting.microphoneCaptureExpected)
        assertFalse(starting.copy(audioStarting = false).microphoneCaptureExpected)
    }

    @Test fun notificationDenialOrBlockedChannelIsEnoughForOneNotice() {
        assertTrue(ready.copy(notificationsEnabled = false).recordingNotificationsBlocked)
        assertTrue(ready.copy(audioChannel = ChannelAccess.BLOCKED).recordingNotificationsBlocked)
        assertFalse(ready.copy(audioChannel = ChannelAccess.NOT_CREATED, notificationsEnabled = null).recordingNotificationsBlocked)
    }
}
