package top.jinso.tacit

import android.app.Application
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
    val vault: Vault get() = synchronized(this) {
        opened ?: Vault(this, prefs) { SyncWorker.enqueue(this, newRecord = true) }.also { opened = it }
    }

    override fun onCreate() {
        super.onCreate()
        if (getProcessName().endsWith(":qnn")) return
        prefs = Preferences(this)
        prefs.dropRemovedSettings()
        top.jinso.tacit.sources.Sources.retireRemovedCollectors(this)
        top.jinso.tacit.audio.AudioMaintenanceWorker.schedule(this)
        Thread({ top.jinso.tacit.data.LegacyFiles.remove(noBackupFilesDir) }, "tacit-legacy-cleanup").apply { isDaemon = true }.start()
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { SyncWorker.enqueue(this@TacitApp) }
            }
        )
    }
}
