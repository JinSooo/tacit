package top.jinso.tacit.ui.onboarding

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.*
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AUDIO_SOURCE
import top.jinso.tacit.audio.AudioRuntime
import top.jinso.tacit.sources.NotificationSource
import top.jinso.tacit.sources.Sources

/** Read off main: initializing the existing audio runtime may open encrypted local storage. */
internal fun readCollectionHealth(app: TacitApp): CollectionHealth {
    fun has(permission: String) = app.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    val sources = Sources.descriptors.map { source ->
        val granted = Sources.granted(app, source.id)
        SourceHealth(source.id, source.title, app.prefs.enabled(source.id), granted, if (granted) "系统权限已允许" else "系统权限尚未允许", app.prefs.status(source.id))
    }
    val audioEnabled = app.prefs.enabled(AUDIO_SOURCE)
    val runtime = if (audioEnabled) runCatching { AudioRuntime.get(app) }.getOrNull() else null
    val notifications = app.getSystemService(NotificationManager::class.java)
    fun channel(id: String): ChannelAccess = runCatching {
        val channel = notifications.getNotificationChannel(id) ?: return@runCatching ChannelAccess.NOT_CREATED
        val groupBlocked = channel.group?.let { notifications.getNotificationChannelGroup(it)?.isBlocked } == true
        if (channel.importance == NotificationManager.IMPORTANCE_NONE || groupBlocked) ChannelAccess.BLOCKED else ChannelAccess.ALLOWED
    }.getOrDefault(ChannelAccess.UNKNOWN)
    val power = app.getSystemService(PowerManager::class.java)
    return CollectionHealth(
        paused = app.prefs.paused, sources = sources,
        microphoneGranted = has(Manifest.permission.RECORD_AUDIO), audioEnabled = audioEnabled,
        audioCaptureWanted = app.prefs.audioCaptureWanted,
        audioRunning = if (audioEnabled) runtime?.recording else false,
        audioStarting = runtime?.let { it.requested && !it.recording } == true,
        audioSilenced = runtime?.silenced == true,
        notificationsEnabled = runCatching { notifications.areNotificationsEnabled() }.getOrNull(),
        audioChannel = channel("tacit.audio"),
        batteryExempt = runCatching { power.isIgnoringBatteryOptimizations(app.packageName) }.getOrNull(),
        backgroundRestricted = runCatching { app.getSystemService(ActivityManager::class.java).isBackgroundRestricted }.getOrNull(),
        powerSave = runCatching { power.isPowerSaveMode }.getOrNull(),
        notificationListenerConnected = if (!app.prefs.paused && sources.any { it.id == Sources.NOTIFICATION && it.enabled && it.granted })
            NotificationSource.connected else null,
    )
}

/** Safe to host at TacitRoot. Reads on every resume and while visible; never starts a service,
 * changes user preferences, asks for permissions, or posts a notification. */
@Composable
internal fun rememberCollectionHealth(app: TacitApp, resumed: Int, refresh: Int = 0): CollectionHealth? {
    val owner = LocalActivity.current as? LifecycleOwner
    var health by remember(app) { mutableStateOf<CollectionHealth?>(null) }
    LaunchedEffect(app, owner, resumed, refresh) {
        owner?.lifecycle?.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                health = withContext(Dispatchers.IO) { readCollectionHealth(app) }
                delay(2_000)
            }
        }
    }
    return health
}

internal enum class SystemPage { APP, NOTIFICATIONS, BATTERY_OPTIMIZATION, BATTERY_SAVER, PRIVACY }

/** OEM pages are deliberately not guessed. Fall back to app info, never report a jump as a grant. */
internal fun openSystemPage(context: Context, page: SystemPage, notify: (String) -> Unit) {
    val appInfo = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri())
    val intent = when (page) {
        SystemPage.APP -> appInfo
        SystemPage.NOTIFICATIONS -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        SystemPage.BATTERY_OPTIMIZATION -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        SystemPage.BATTERY_SAVER -> Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
        SystemPage.PRIVACY -> Intent(Settings.ACTION_PRIVACY_SETTINGS)
    }
    fun launch(target: Intent) = runCatching { context.startActivity(target.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess
    if (!launch(intent)) {
        if (page != SystemPage.APP && launch(appInfo)) notify("这台手机没有提供直接入口，请在应用信息中检查")
        else notify("无法打开系统设置，请从手机设置中找到 Tacit")
    }
}
