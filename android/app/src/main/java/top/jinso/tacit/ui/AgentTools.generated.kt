// Generated from packages/record/agent-tools.ts. Regenerate with bun packages/record/generate-agent-tools.ts.
package top.jinso.tacit.ui

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import top.jinso.tacit.R

internal data class AgentSessionTool(
    @StringRes val label: Int,
    val appPackage: String?,
    @DrawableRes val glyph: Int,
)

internal val agentSessionTools = mapOf(
    "claude_code.session" to AgentSessionTool(R.string.source_claude_code, "com.anthropic.claude", R.drawable.ph_asterisk),
    "codex.session" to AgentSessionTool(R.string.source_codex, "com.openai.chatgpt", R.drawable.ph_open_ai_logo),
    "antigravity.session" to AgentSessionTool(R.string.source_antigravity, null, R.drawable.ph_terminal_window),
    "opencode.session" to AgentSessionTool(R.string.source_opencode, null, R.drawable.ph_terminal_window),
    "codebuddy.session" to AgentSessionTool(R.string.source_codebuddy, null, R.drawable.ph_terminal_window),
    "workbuddy.session" to AgentSessionTool(R.string.source_workbuddy, null, R.drawable.ph_terminal_window),
    "copilot_cli.session" to AgentSessionTool(R.string.source_copilot_cli, null, R.drawable.ph_terminal_window),
    "droid.session" to AgentSessionTool(R.string.source_droid, null, R.drawable.ph_terminal_window),
    "qwen_code.session" to AgentSessionTool(R.string.source_qwen_code, null, R.drawable.ph_terminal_window),
    "gemini_cli.session" to AgentSessionTool(R.string.source_gemini_cli, null, R.drawable.ph_terminal_window),
)
