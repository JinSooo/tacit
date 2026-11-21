package top.jinso.tacit.ui.components

import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.sourceName
import top.jinso.tacit.ui.tacitColors

private class CachedIcon(val bitmap: ImageBitmap?)
private val icons = LruCache<String, CachedIcon>(96)

@Composable
internal fun SourceIcon(source: String, packageName: String? = null, size: Dp = 16.dp, description: String = sourceName(source)) {
    val manager = LocalContext.current.packageManager
    val bitmap = if (packageName.isNullOrBlank()) null else key(packageName) {
        val entry by produceState(icons.get(packageName), packageName) {
            if (value == null) {
                value = withContext(Dispatchers.IO) {
                    val image = runCatching {
                        manager.getApplicationIcon(packageName).toBitmap(64, 64).asImageBitmap()
                    }.getOrNull()
                    CachedIcon(image).also { icons.put(packageName, it) }
                }
            }
        }
        entry?.bitmap
    }
    if (bitmap != null) Image(bitmap, description, Modifier.size(size))
    else Icon(when (source) {
        Sources.AUDIO -> Icons.Outlined.Mic
        Sources.NOTE, Sources.CORRECTION -> Icons.Outlined.Edit
        Sources.NOTIFICATION -> Icons.Outlined.ChatBubbleOutline
        Sources.USAGE -> Icons.Outlined.GridView
        "system.pause" -> Icons.Outlined.Pause
        else -> Icons.Outlined.Description
    }, description, Modifier.size(size), tint = tacitColors.muted)
}
