package top.jinso.tacit.sync

import android.content.Context
import android.os.SystemClock
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.TacitApp
import java.util.concurrent.TimeUnit.MILLISECONDS
import java.util.concurrent.TimeUnit.MINUTES

internal class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val sync = (applicationContext as TacitApp).sync
        if (inputData.getBoolean("timeline", false)) sync.refreshTimeline()
        sync.run(inputData.getBoolean("retry", false))
        Result.success()
    }

    companion object {
        private const val PERIODIC = "tacit-mac-sync-periodic"
        private const val TAG = "tacit-mac-sync"
        private val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        fun schedulePeriodic(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, MINUTES)
                .setInputData(androidx.work.workDataOf("timeline" to true)).setConstraints(network).addTag(TAG).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, request)
        }

        private var lastRecordTrigger: Long? = null

        @Synchronized fun enqueue(context: Context, newRecord: Boolean = false) {
            if (newRecord) {
                val now = SystemClock.elapsedRealtime()
                if (lastRecordTrigger?.let { now - it < 30_000 } == true) return
                lastRecordTrigger = now
            }
            val request = OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(network).addTag(TAG)
                .setInitialDelay(if (newRecord) 30_000 else 0, MILLISECONDS).build()
            // An open/network trigger can advance a delayed send. A new burst can queue behind
            // a running record-triggered job, so its last insert cannot be lost at job completion.
            val lane = if (newRecord) "record" else "now"
            val policy = if (newRecord) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP
            WorkManager.getInstance(context).enqueueUniqueWork("$TAG-$lane", policy, request)
        }

        fun retry(context: Context, delayMillis: Long) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(network).addTag(TAG)
                .setInputData(androidx.work.workDataOf("retry" to true)).setInitialDelay(delayMillis, MILLISECONDS).build()
            WorkManager.getInstance(context).enqueueUniqueWork("$TAG-retry", ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        }

        @Synchronized fun cancel(context: Context) {
            lastRecordTrigger = null
            WorkManager.getInstance(context).cancelAllWorkByTag(TAG)
        }
    }
}
