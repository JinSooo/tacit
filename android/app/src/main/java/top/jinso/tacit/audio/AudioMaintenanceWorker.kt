package top.jinso.tacit.audio

import android.content.Context
import androidx.work.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

class AudioMaintenanceWorker(context:Context,params:WorkerParameters):CoroutineWorker(context,params) {
    override suspend fun doWork():Result=withContext(Dispatchers.IO){try{AudioController(applicationContext).prune().get();Result.success()}catch(_:Exception){Result.retry()}}
    companion object {
        fun schedule(context:Context) {WorkManager.getInstance(context).enqueueUniquePeriodicWork("tacit-audio-retention",ExistingPeriodicWorkPolicy.KEEP,PeriodicWorkRequestBuilder<AudioMaintenanceWorker>(1,TimeUnit.DAYS).build())}
    }
}
