import { AGENT_SESSIONS, AGENT_TOOLS } from "./agent-tools.ts";

const command = "bun packages/record/generate-agent-tools.ts";
const stamp = `Generated from packages/record/agent-tools.ts. Regenerate with ${command}.`;
const android = "android/app/src/main";
const stringName = (source: string) => `source_${source.split(".")[0]}`;
const kotlinValue = (value: string | undefined) => value === undefined ? "null" : JSON.stringify(value).replaceAll("$", "\\$");
const androidText = (value: string) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  .replaceAll("'", "\\'").replaceAll('"', '\\"');

const swiftValue = (value: string | undefined) => value === undefined ? "nil" : JSON.stringify(value);

const androidStrings = `<?xml version="1.0" encoding="utf-8"?>
<!-- ${stamp} -->
<resources>
${AGENT_SESSIONS.map(({ source, label }) => `    <string name="${stringName(source)}">${androidText(label)}</string>`).join("\n")}
</resources>
`;

export const nativeAgentTools = {
  "collector/Sources/CollectorCore/AgentTools.generated.swift": `// ${stamp}

extension AgentTools {
  static let entries: [Tool] = [
${AGENT_TOOLS.map(tool => `    Tool(id: ${swiftValue(tool.id)}, source: ${swiftValue(tool.source)}, label: ${swiftValue(tool.label)}, bundle: ${swiftValue(tool.macBundle)}, symbol: ${swiftValue(tool.symbol ?? "terminal-window")}, alias: ${swiftValue(tool.macAlias)}, substitute: ${swiftValue(tool.macSubstitute)}),`).join("\n")}
  ]
}
`,
  [`${android}/java/top/jinso/tacit/ui/AgentTools.generated.kt`]: `// ${stamp}
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
${AGENT_SESSIONS.map(({ source, androidPackage, symbol }) => `    ${kotlinValue(source)} to AgentSessionTool(R.string.${stringName(source)}, ${kotlinValue(androidPackage)}, R.drawable.ph_${(symbol ?? "terminal-window").replaceAll("-", "_")}),`).join("\n")}
)
`,
  [`${android}/res/values/agent_tools.xml`]: androidStrings,
  [`${android}/res/values-zh/agent_tools.xml`]: androidStrings,
};

if (import.meta.main) {
  for (const [path, source] of Object.entries(nativeAgentTools)) {
    await Bun.write(new URL(`../../${path}`, import.meta.url), source);
  }
}
