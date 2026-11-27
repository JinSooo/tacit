package top.jinso.tacit.ui.components

import android.content.Context
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import top.jinso.tacit.R
import top.jinso.tacit.sources.Sources
import top.jinso.tacit.ui.agentSessionTools
import top.jinso.tacit.ui.uiFormat
import top.jinso.tacit.ui.tacitColors
import java.util.concurrent.ConcurrentHashMap

/** 来源对应的手机应用：装了就用它自己的图标，和 Mac 上用真实应用图标一样。包名需同时列在清单的 queries 里。 */
private val sourceApps = mapOf("mac.wechat" to "com.tencent.mm")

/** 没有对应应用时画和 Mac 同一套 Phosphor 符号；手机录音是手机外形，Mac 录音是麦克风。 */
@DrawableRes
private fun glyph(source: String): Int = when (source) {
    Sources.AUDIO -> R.drawable.ph_device_mobile_speaker
    "mac.audio" -> R.drawable.ph_microphone
    "mac.wechat" -> R.drawable.ph_chats_circle
    "mac.browser" -> R.drawable.ph_globe
    "mac.screen", "mac.app" -> R.drawable.ph_browser
    Sources.NOTIFICATION -> R.drawable.ph_chat_circle_dots
    Sources.USAGE -> R.drawable.ph_device_mobile
    Sources.NOTE, "manual.agent" -> R.drawable.ph_pencil_simple_line
    Sources.CORRECTION -> R.drawable.ph_note_pencil
    else -> R.drawable.ph_circle_dashed
}

private object AppIcons {
    private val cache = ConcurrentHashMap<String, Result<ImageBitmap>>()
    fun cached(pkg: String): ImageBitmap? = cache[pkg]?.getOrNull()
    fun load(context: Context, pkg: String): ImageBitmap? = cache.getOrPut(pkg) {
        runCatching { context.packageManager.getApplicationIcon(pkg).toBitmap(96, 96).asImageBitmap() }
    }.getOrNull()
}

@Composable
internal fun SourceIcon(source: String, size: Dp = 16.dp) {
    val context = LocalContext.current
    val tool = agentSessionTools[source]
    val pkg = tool?.appPackage ?: sourceApps[source]
    val app by produceState(pkg?.let(AppIcons::cached), pkg) {
        if (pkg != null) value = withContext(Dispatchers.IO) { AppIcons.load(context.applicationContext, pkg) }
    }
    val name = uiFormat().sourceName(source)
    val icon = app
    if (icon != null) {
        Image(icon, name, Modifier.size(size))
    } else {
        Box(Modifier.size(size).background(tacitColors.fill, RoundedCornerShape(size * 0.28f))
            .semantics { contentDescription = name }, contentAlignment = Alignment.Center) {
            Icon(painterResource(tool?.glyph ?: glyph(source)), null, Modifier.size(size * 0.66f), tint = tacitColors.muted)
        }
    }
}

