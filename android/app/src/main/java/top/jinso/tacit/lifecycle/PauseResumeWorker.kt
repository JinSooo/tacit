package top.jinso.tacit.lifecycle

import android.content.Context
import androidx.work.*
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.Draft
import top.jinso.tacit.sources.Sources
import java.util.concurrent.TimeUnit

class PauseResumeWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val app = applicationContext as TacitApp
        if (app.prefs.paused) return Result.success()
        Sources.refresh(app)
        return Result.success()
    }
    companion object {
        fun change(app: TacitApp, paused: Boolean, until: Long = 0) {
            val wasPaused = app.prefs.paused
            app.prefs.setPause(paused, until)
            if (paused) AudioController(app).stop(discardPending = true)
            Sources.refresh(app)
            val manager = WorkManager.getInstance(app)
            manager.cancelUniqueWork("tacit-resume")
            if (paused && until > 0) manager.enqueueUniqueWork("tacit-resume", ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<PauseResumeWorker>().setInitialDelay((until-System.currentTimeMillis()).coerceAtLeast(0), TimeUnit.MILLISECONDS).build())
            if (paused && !wasPaused) java.util.concurrent.CompletableFuture.runAsync {
                runCatching { app.vault.ingest(Draft("system.pause", "采集已暂停", "暂停期间不自动记录。", method = "manual")) }
            }
        }
    }
}
