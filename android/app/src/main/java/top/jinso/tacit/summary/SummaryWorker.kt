package top.jinso.tacit.summary

import android.content.Context
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.readableTranscript
import top.jinso.tacit.data.ConversationSummary
import top.jinso.tacit.sources.Sources
import java.util.concurrent.TimeUnit.MINUTES

/** Writes a summary for each finished conversation, like the Mac does, when the user turned on "AI 总结". */
internal class PhoneSummarizer(private val app: TacitApp) {
    private val vault get() = app.vault

    fun model(): SummaryModel? = vault.summaryModel()?.takeIf { it.optBoolean("enabled") }?.let {
        SummaryModel(it.optString("base"), it.optString("model"), it.optString("key"))
    }

    suspend fun run(now: Long = System.currentTimeMillis()): Int = lock.withLock {
        val model = model() ?: return@withLock 0
        val state = vault.summaryModel() ?: return@withLock 0
        if (state.optLong("pausedUntil") > now) return@withLock 0
        val client = try { SummaryClient(model) } catch (e: SummaryFailure) { fail(e); return@withLock 0 }
        val audio = AudioController(app)
        var written = 0
        for (g in todo(now, audio)) {
            val (group, turns) = g
            val summary = try { client.summarize(group.start, group.end, summaryTranscript(turns)) }
                catch (e: SummaryFailure) { fail(e, now); break }
            // The user may have deleted part of it while the model was writing; then the next round starts over.
            val current = groups(now).firstOrNull { it.id == group.id }
            if (current?.recordIds != group.recordIds) continue
            vault.saveOwnSummary(ConversationSummary(group.id, group.recordIds, group.start, group.end, summary.title, summary.summary, summary.points))
            written++
        }
        if (written > 0) vault.summaryModel()?.let { vault.saveSummaryModel(it.apply { remove("error"); remove("pausedUntil") }) }
        written
    }

    private fun groups(now: Long): List<SummaryGroup> {
        val records = vault.list(source = Sources.AUDIO, limit = 20_000, from = now - SummaryRules.WINDOW_MS - SummaryRules.GAP_MS)
        return groupConversations(records) { r -> latestCorrection(r.id)?.sensitivity ?: r.sensitivity }
    }

    private fun latestCorrection(id: String) = vault.corrections(id).maxWithOrNull(compareBy({ it.start }, { it.id }))

    private fun todo(now: Long, audio: AudioController): List<Pair<SummaryGroup, List<SummaryTurn>>> {
        val own = vault.ownSummaries().map { it.recordIds.toSet() }.toSet()
        val mac = vault.macSummaries().map { it.recordIds.toSet() }.toSet()
        return groups(now).filter { g ->
            now - g.end >= SummaryRules.GAP_MS && now - g.end <= SummaryRules.WINDOW_MS && !g.private &&
                g.recordIds.toSet().let { it !in own && it !in mac }
        // Lazy: rendering a long conversation takes seconds, so only the ones this round will write.
        }.sortedByDescending { it.start }.asSequence().mapNotNull { g ->
            val turns = g.recordIds.mapNotNull(vault::get).sortedBy { it.start }.flatMap { r ->
                val body = latestCorrection(r.id)?.body
                    ?: readableTranscript(runCatching { audio.renderTranscript(r.id, r.body).get() }.getOrDefault(r.body))
                summaryTurns(r.start, body)
            }
            if (turns.sumOf { it.text.length } < SummaryRules.MIN_CHARS) null else g to turns
        }.take(SummaryRules.PER_ROUND).toList()
    }

    private fun fail(e: SummaryFailure, now: Long = System.currentTimeMillis()) {
        val state = vault.summaryModel() ?: return
        state.put("error", e.reason)
        if (e.retryAfterMs > 0) state.put("pausedUntil", now + e.retryAfterMs)
        vault.saveSummaryModel(state)
    }

    companion object { private val lock = Mutex() }
}

internal class SummaryWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val app = applicationContext as TacitApp
        if (PhoneSummarizer(app).run() > 0 && app.vault.syncConnection()?.optBoolean("removed") == false) top.jinso.tacit.sync.SyncWorker.enqueue(app)
        Result.success()
    }

    companion object {
        private const val PERIODIC = "tacit-summary-periodic"
        private const val TAG = "tacit-summary"
        private val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /** On while "AI 总结" is on: every 15 minutes, plus once now. */
        fun apply(context: Context, on: Boolean) {
            val work = WorkManager.getInstance(context)
            if (!on) { work.cancelAllWorkByTag(TAG); return }
            work.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<SummaryWorker>(15, MINUTES).setConstraints(network).addTag(TAG).build())
            work.enqueueUniqueWork("$TAG-now", ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<SummaryWorker>().setConstraints(network).addTag(TAG).build())
        }
    }
}

internal fun summaryModelJson(enabled: Boolean, model: SummaryModel): JSONObject =
    JSONObject().put("enabled", enabled).put("base", model.base.trim()).put("model", model.model.trim()).put("key", model.key.trim())
