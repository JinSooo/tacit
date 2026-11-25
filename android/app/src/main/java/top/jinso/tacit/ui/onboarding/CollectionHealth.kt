package top.jinso.tacit.ui.onboarding

/** Observed facts only. Enabled means intent, never proof that a service is running. */
internal data class CollectionHealth(
    val microphoneGranted: Boolean,
    val audioEnabled: Boolean,
    val audioCaptureWanted: Boolean,
    val audioRunning: Boolean?,
    val audioStarting: Boolean,
    val notificationsEnabled: Boolean?,
    val audioChannel: ChannelAccess,
    val batteryExempt: Boolean?,
    val backgroundRestricted: Boolean?,
    val powerSave: Boolean?,
    val notificationPermissionMissing: Boolean = false,
) {
    val microphoneCaptureExpected: Boolean
        get() = audioEnabled && (audioCaptureWanted || audioRunning == true || audioStarting)

    val recordingNotificationsBlocked: Boolean
        get() = notificationsEnabled == false || audioChannel == ChannelAccess.BLOCKED
}

internal enum class ChannelAccess { NOT_CREATED, ALLOWED, BLOCKED, UNKNOWN }
