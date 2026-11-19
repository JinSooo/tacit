package top.jinso.tacit.data

import java.io.File

/** 0.3 留在 no_backup 里、0.4 起不再使用的目录：本机总结模型（约 1 GB）和离线 OCR 数据。 */
internal object LegacyFiles {
    val directories = listOf("summary-model", "offline-ocr")

    /** 返回实际删除的目录名；不存在的跳过，删不掉的下次启动再试。 */
    fun remove(noBackup: File): List<String> = directories.filter { name ->
        val dir = File(noBackup, name)
        dir.exists() && dir.deleteRecursively()
    }
}
