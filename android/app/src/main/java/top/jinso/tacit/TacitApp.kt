package top.jinso.tacit

import android.app.Application
import top.jinso.tacit.data.Preferences
import top.jinso.tacit.data.Vault

class TacitApp : Application() {
    lateinit var prefs: Preferences; private set
    private var opened: Vault? = null
    val vault: Vault get() = synchronized(this) { opened ?: Vault(this, prefs).also { opened = it } }
    override fun onCreate() { super.onCreate(); if (getProcessName().endsWith(":qnn")) return; prefs = Preferences(this); top.jinso.tacit.audio.AudioMaintenanceWorker.schedule(this) }
}
