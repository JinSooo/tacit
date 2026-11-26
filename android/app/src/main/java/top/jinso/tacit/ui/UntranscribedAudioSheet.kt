package top.jinso.tacit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import top.jinso.tacit.R
import top.jinso.tacit.audio.conversationPlaybackKey
import top.jinso.tacit.ui.components.Caption
import top.jinso.tacit.ui.components.GroupCard
import top.jinso.tacit.ui.components.TextAction
import top.jinso.tacit.ui.components.TonalButton

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun UntranscribedAudioSheet(
    scenes: List<AudioConversationRow>,
    modelsReady: Boolean,
    busy: Boolean,
    playingKey: String?,
    onTogglePlay: (String) -> Unit,
    onTranscribe: (AudioConversationRow) -> Unit,
    onDelete: (AudioConversationRow) -> Unit,
    onDismiss: () -> Unit,
) {
    val format = uiFormat()
    val strings = uiStrings()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var pendingDelete by remember { mutableStateOf<AudioConversationRow?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        shape = RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp),
        containerColor = tacitColors.paper,
        contentColor = tacitColors.ink,
        dragHandle = { BottomSheetDefaults.DragHandle(color = tacitColors.faint) },
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(start = 20.dp, end = 20.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    strings.text(R.string.untranscribed_audio_title),
                    style = MaterialTheme.typography.titleLarge,
                    fontFamily = FontFamily.Serif,
                    fontWeight = FontWeight.Normal,
                    color = tacitColors.ink,
                )
                Caption(strings.text(R.string.untranscribed_audio_hint))
            }

            LazyColumn(
                Modifier.fillMaxWidth().weight(1f, fill = false),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                contentPadding = PaddingValues(bottom = 4.dp),
            ) {
                items(scenes, key = { it.conversationId }) { scene ->
                    val isPlaying = playingKey == conversationPlaybackKey(scene.conversationId)
                    GroupCard {
                        Column(
                            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Row(
                                Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(
                                        format.timeRangeLabel(scene.start, scene.end),
                                        style = MaterialTheme.typography.bodyLarge,
                                        fontWeight = FontWeight.Medium,
                                        color = tacitColors.ink,
                                    )
                                    Caption(format.durationLabel((scene.end - scene.start).coerceAtLeast(0L)))
                                }
                                if (scene.audioAvailable || isPlaying) {
                                    IconButton(
                                        onClick = { onTogglePlay(scene.conversationId) },
                                        enabled = !busy,
                                    ) {
                                        Icon(
                                            if (isPlaying) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                                            if (isPlaying) strings.text(R.string.preview_stop) else strings.text(R.string.preview_play),
                                            tint = if (isPlaying) tacitColors.accent else tacitColors.ink,
                                        )
                                    }
                                }
                            }
                            Row(
                                Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Box(Modifier.weight(1f)) {
                                    when {
                                        scene.transcribePending -> Caption(
                                            strings.text(
                                                if (modelsReady) R.string.untranscribed_transcribing
                                                else R.string.untranscribed_waiting_models,
                                            ),
                                            color = tacitColors.accent,
                                        )
                                        scene.userConfirmed -> Caption(strings.text(R.string.untranscribed_no_speech))
                                        scene.audioAvailable -> TonalButton(
                                            strings.text(R.string.transcribe_this_clip),
                                            onClick = { onTranscribe(scene) },
                                            enabled = !busy,
                                        )
                                        else -> Caption(strings.text(R.string.untranscribed_expired))
                                    }
                                }
                                TextAction(
                                    strings.text(R.string.delete),
                                    onClick = { pendingDelete = scene },
                                    enabled = !busy,
                                    color = tacitColors.attention,
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    val target = pendingDelete
    if (target != null) {
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(strings.text(R.string.delete_untranscribed_title)) },
            text = { Text(strings.text(R.string.delete_untranscribed_message)) },
            confirmButton = {
                TextAction(
                    strings.text(R.string.delete),
                    onClick = {
                        pendingDelete = null
                        onDelete(target)
                    },
                    enabled = !busy,
                    color = tacitColors.attention,
                )
            },
            dismissButton = {
                TextAction(strings.text(R.string.cancel), onClick = { pendingDelete = null })
            },
        )
    }
}
