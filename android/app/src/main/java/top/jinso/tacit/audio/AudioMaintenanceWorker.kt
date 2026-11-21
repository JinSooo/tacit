package top.jinso.tacit.audio

import android.content.Context
import androidx.work.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

class AudioMaintenanceWorker(context:Context,params:WorkerParameters):CoroutineWorker(context,params) {
    override suspend fun doWork():Result=withContext(Dispatchers.IO){try{AudioController(applicationContext).prune().get();Result.success()}catch(_:Exception){Result.retry()}}
    companion object {
        fun schedule(context:Context) {
            val work=WorkManager.getInstance(context)
            work.enqueueUniquePeriodicWork("tacit-audio-retention",ExistingPeriodicWorkPolicy.KEEP,PeriodicWorkRequestBuilder<AudioMaintenanceWorker>(1,TimeUnit.DAYS).build())
            work.enqueueUniqueWork("tacit-audio-tagging",ExistingWorkPolicy.KEEP,OneTimeWorkRequestBuilder<MusicModelWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL,30,TimeUnit.MINUTES).build())
        }
    }
}

/** Installs that predate the music detector fetch its two fixed files once; the check itself is a file stat. */
class MusicModelWorker(context:Context,params:WorkerParameters):CoroutineWorker(context,params) {
    override suspend fun doWork():Result=withContext(Dispatchers.IO){
        val models=SpeechModels(applicationContext)
        if(!models.taggingMissing()) return@withContext Result.success()
        try{models.supplementTagging();Result.success()}catch(_:Exception){if(runAttemptCount<5)Result.retry() else Result.failure()}
    }
}
