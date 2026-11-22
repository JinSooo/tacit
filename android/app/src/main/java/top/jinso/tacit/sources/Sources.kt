package top.jinso.tacit.sources

import android.content.Context
import android.content.pm.ShortcutManager
import androidx.work.WorkManager

object Sources {
    const val AUDIO = "android.audio"
    const val NOTE = "manual.note"
    const val CORRECTION = "manual.correction"
    /** 0.4.1 及以前采集的来源：手机已不再采集，留在本机的记录仍可上传和查看。 */
    const val USAGE = "android.usage"
    const val NOTIFICATION = "android.notification"
    val UPLOADABLE: Set<String> = setOf(AUDIO, NOTIFICATION, USAGE, NOTE, CORRECTION)

    /** 手机只录音（0.4.2 起）：撤掉旧版本留下的应用使用定时任务、暂停后自动继续和桌面补写快捷方式。 */
    fun retireRemovedCollectors(context: Context) {
        val work = WorkManager.getInstance(context)
        listOf("tacit-usage-periodic", "tacit-usage-open", "tacit-resume").forEach(work::cancelUniqueWork)
        runCatching {
            context.getSystemService(ShortcutManager::class.java)
                .disableShortcuts(listOf("write"), "Tacit 手机端只录音，不再补写")
        }
    }
}
