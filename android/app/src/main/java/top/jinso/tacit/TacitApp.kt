package top.jinso.tacit

import android.app.Application
import top.jinso.tacit.i18n.AppLocale
import android.net.ConnectivityManager
import android.net.Network
import top.jinso.tacit.sync.SyncCoordinator
import top.jinso.tacit.sync.SyncWorker
import top.jinso.tacit.data.Preferences
import top.jinso.tacit.data.Vault

class TacitApp : Application() {
    lateinit var prefs: Preferences; private set
    private var opened: Vault? = null
    internal val sync by lazy { SyncCoordinator(this) }
    internal val updates by lazy { top.jinso.tacit.data.UpdateCheck(this, BuildConfig.VERSION_NAME) }
    val vault: Vault get() = synchronized(this) {
        opened ?: Vault(this, prefs) { SyncWorker.enqueue(this, newRecord = true) }.also { opened = it }
    }

    internal fun resumeSummaryWorker() {
        Thread({
            // Opening can fail while keys or the database are unavailable. Let the foreground offer a retry.
            val enabled = runCatching { vault.summaryModel()?.optBoolean("enabled") == true }.getOrDefault(false)
            if (enabled) top.jinso.tacit.summary.SummaryWorker.apply(this, true)
        }, "tacit-summary-start").apply { isDaemon = true }.start()
    }

    override fun onCreate() {
        super.onCreate()
        if (getProcessName().endsWith(":qnn")) return
        AppLocale.initialize(this)
        prefs = Preferences(this)
        prefs.dropRemovedSettings()
        top.jinso.tacit.sources.Sources.retireRemovedCollectors(this)
        top.jinso.tacit.audio.AudioMaintenanceWorker.schedule(this)
        resumeSummaryWorker()
        Thread({ top.jinso.tacit.data.LegacyFiles.remove(noBackupFilesDir) }, "tacit-legacy-cleanup").apply { isDaemon = true }.start()
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { SyncWorker.enqueue(this@TacitApp) }
            }
        )
    }
}
