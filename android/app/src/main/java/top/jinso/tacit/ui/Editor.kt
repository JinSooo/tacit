package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import top.jinso.tacit.ui.components.*

@Composable
internal fun Editor(draft: EditorDraftModel, onClose: () -> Unit, onSave: suspend (String, String, Boolean) -> Unit) {
    val target = draft.correction
    LaunchedEffect(target?.id, draft.initial) {
        draft.open(target?.id ?: "new", target?.title.orEmpty(), draft.initial, target?.sensitivity == "private")
    }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val started = remember { System.currentTimeMillis() }
    Column(Modifier.fillMaxSize().imePadding()) {
        PageBar(if (target == null) "补写" else "修正记录", onClose, close = true) {
            IconToggleButton(checked = draft.private, onCheckedChange = { draft.private = it }, enabled = !saving) {
                Icon(if (draft.private) Icons.Outlined.Lock else Icons.Outlined.LockOpen,
                    "私密", tint = if (draft.private) tacitColors.accent else tacitColors.muted)
            }
            TextAction(
                if (saving) "保存中" else "保存",
                onClick = {
                    scope.launch {
                        saving = true
                        try {
                            val title = draft.title.trim().ifEmpty {
                                draft.body.lineSequence().firstOrNull { it.isNotBlank() }?.take(80) ?: "补写"
                            }
                            onSave(title, draft.body, draft.private)
                        } finally { saving = false }
                    }
                },
                enabled = draft.body.isNotBlank() && !saving, color = tacitColors.accent, weight = FontWeight.SemiBold,
            )
        }
        Column(Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Caption(if (target != null) "修正会另存一条，原文仍保留。" else date(started, "M 月 d 日 HH:mm"))
            DraftField(draft.title, { draft.title = it.take(200) }, "标题", Modifier.fillMaxWidth().heightIn(min = 48.dp),
                MaterialTheme.typography.headlineMedium.copy(fontFamily = FontFamily.Serif), singleLine = true, enabled = !saving)
            DraftField(draft.body, { draft.body = it.take(200000) },
                if (draft.sharedOrigin) "分享内容" else "发生了什么", Modifier.weight(1f).fillMaxWidth(),
                MaterialTheme.typography.bodyLarge, singleLine = false, enabled = !saving)
        }
    }
}

@Composable
private fun DraftField(value: String, update: (String) -> Unit, placeholder: String, modifier: Modifier,
    style: TextStyle, singleLine: Boolean, enabled: Boolean) {
    BasicTextField(
        value, update, modifier, enabled = enabled, textStyle = style.copy(color = tacitColors.ink),
        singleLine = singleLine, cursorBrush = SolidColor(tacitColors.ink),
        decorationBox = { field ->
            Box(contentAlignment = if (singleLine) Alignment.CenterStart else Alignment.TopStart) {
                if (value.isEmpty()) Text(placeholder, color = tacitColors.faint, style = style)
                field()
            }
        },
    )
}
