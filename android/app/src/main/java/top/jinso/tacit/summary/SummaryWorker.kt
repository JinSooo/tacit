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
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import top.jinso.tacit.TacitApp
import top.jinso.tacit.audio.AudioController
import top.jinso.tacit.core.readableTranscript
import top.jinso.tacit.i18n.AppLocale
import top.jinso.tacit.i18n.UiStrings
import top.jinso.tacit.i18n.speechUnits
import top.jinso.tacit.data.ConversationSummary
import top.jinso.tacit.data.Vault
import top.jinso.tacit.sources.Sources
import java.util.concurrent.TimeUnit.MINUTES

/** Writes a summary for each finished conversation, like the Mac does, when the user turned on "AI 总结". */
internal class PhoneSummarizer(private val app: TacitApp) {
    private val vault get() = app.vault

    suspend fun run(now: Long = System.currentTimeMillis()): Int = lock.withLock {
        val state = vault.summaryModel()?.takeIf { it.optBoolean("enabled") } ?: return@withLock 0
        val model = state.summaryModelConfig()
        val pending = todo(now, AudioController(app))
        if (pending.isEmpty()) {
            // 没有要写的就只清会自动重试的错误；key 无效这类要用户处理的留着，免得删掉那场对话后错误也跟着没了。
            vault.clearSummaryFailure(model, requireEnabled = true, onlyRetryable = true)
            return@withLock 0
        }
        if (state.optLong("pausedUntil") > now) return@withLock 0
        val paired = vault.syncConnection()?.optBoolean("removed") == false
        val lang = summaryLanguage(paired, app.prefs.hubLanguage, AppLocale.language(app))
        val client = try {
            SummaryClient(model, lang)
        } catch (e: SummaryFailure) {
            fail(model, e)
            return@withLock 0
        }
        var written = 0
        for ((group, turns) in pending) {
            currentCoroutineContext().ensureActive()
            if (!vault.usesSummaryModel(model)) break
            val summary = try {
                client.summarize(group.start, group.end, summaryTranscript(turns, lang = lang))
            } catch (e: SummaryFailure) {
                fail(model, e)
                break
            }
            currentCoroutineContext().ensureActive()
            synchronized(vault) {
                if (!vault.usesSummaryModel(model)) return@synchronized
                vault.clearSummaryFailure(model, requireEnabled = true)
                // A deletion can change the group while the model is writing.
                val current = groups(now).firstOrNull { it.id == group.id }
                if (current?.recordIds != group.recordIds || current.private) return@synchronized
                vault.saveOwnSummary(ConversationSummary(group.id, group.recordIds, group.start, group.end, summary.title, summary.summary, summary.points))
                written++
            }
        }
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
            if (turns.sumOf { speechUnits(it.text) } < SummaryRules.MIN_CHARS) null else g to turns
        }.take(SummaryRules.PER_ROUND).toList()
    }

    private suspend fun fail(model: SummaryModel, failure: SummaryFailure) {
        currentCoroutineContext().ensureActive()
        synchronized(vault) {
            val state = vault.summaryModel()?.takeIf { it.usesSummaryModel(model) } ?: return
            val now = System.currentTimeMillis()
            state.recordSummaryFailure(failure, now)
            vault.saveSummaryModel(state)
        }
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


internal fun savedSummaryModel(previous: JSONObject?, draft: SummaryModel, turnOn: Boolean): JSONObject {
    val previousModel = previous?.summaryModelConfig()
    val hadValidConfig = previousModel != null && previousModel.model.isNotBlank() &&
        runCatching { SummaryClient.endpointOf(previousModel.base) }.isSuccess
    val enabled = turnOn || !hadValidConfig || previous?.optBoolean("enabled") == true
    return previous?.takeIf { previousModel == draft }?.put("enabled", enabled) ?: summaryModelJson(enabled, draft)
}

internal fun JSONObject.summaryModelConfig(): SummaryModel =
    SummaryModel(optString("base"), optString("model"), optString("key"))

private fun JSONObject.usesSummaryModel(model: SummaryModel): Boolean =
    optBoolean("enabled") && summaryModelConfig() == model

private fun Vault.usesSummaryModel(model: SummaryModel): Boolean =
    summaryModel()?.usesSummaryModel(model) == true

internal data class SummaryProblem(val error: SummaryError, val firstFailureAt: Long) {
    val showAt: Long get() = if (error.needsUser) firstFailureAt else firstFailureAt + 60 * 60_000L
    fun messageAt(now: Long, strings: UiStrings): String? = if (now >= showAt) error.reason(strings) else null
}

internal fun JSONObject.summaryProblem(): SummaryProblem? {
    val kind = optString("errorCategory")
    val firstFailureAt = optLong("firstFailureAt")
    return SummaryError.entries.firstOrNull { it.name == kind }
        ?.takeIf { has("firstFailureAt") }
        ?.let { SummaryProblem(it, firstFailureAt) }
}

internal fun JSONObject.recordSummaryFailure(failure: SummaryFailure, now: Long) {
    val firstFailureAt = summaryProblem()?.firstFailureAt ?: now
    remove("error") // Upgrades may still have a legacy message containing an HTTP status.
    put("errorCategory", failure.error.name)
    put("firstFailureAt", firstFailureAt)
    if (failure.retryAfterMs > 0) put("pausedUntil", now + failure.retryAfterMs)
}

internal fun JSONObject.clearSummaryFailure(): Boolean {
    val keys = listOf("error", "errorCategory", "firstFailureAt", "pausedUntil")
    val changed = keys.any(::has)
    keys.forEach(::remove)
    return changed
}

internal fun Vault.clearSummaryFailure(model: SummaryModel, requireEnabled: Boolean = false, onlyRetryable: Boolean = false) = synchronized(this) {
    val state = summaryModel() ?: return@synchronized
    val needsUser = runCatching { SummaryError.valueOf(state.optString("errorCategory")).needsUser }.getOrDefault(false)
    if (onlyRetryable && needsUser) return@synchronized
    if (state.summaryModelConfig() == model && (!requireEnabled || state.optBoolean("enabled")) &&
        state.clearSummaryFailure()
    ) saveSummaryModel(state)
}
