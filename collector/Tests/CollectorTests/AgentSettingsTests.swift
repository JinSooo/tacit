import AppKit
@testable import CollectorCore
import SwiftUI
import Testing
@testable import Collector

private let config = AgentMCPConfig(
  command: "/Applications/Tacit.app/Contents/Helpers/Tacit",
  args: ["/Users/sample/Library/Application Support/Tacit/runtime/hub/src/cli.ts", "mcp", "--tool", "mcp"]
)

@Test func genericAgentInstructionsUseThePathsReturnedByTheHub() throws {
  let payload = """
    {
      "tools": [],
      "other_mcp": {
        "command": "/Applications/Tacit.app/Contents/Helpers/Tacit",
        "args": ["/Users/sample/Library/Application Support/Tacit/runtime/hub/src/cli.ts", "mcp", "--tool", "mcp"]
      }
    }
    """
  let model = try HubJSON.decoder().decode(AgentSettingsData.self, from: Data(payload.utf8))
  let decoded = try JSONDecoder().decode([String: [String: AgentMCPConfig]].self, from: Data(model.otherMcp.json.utf8))
  let mcp = try #require(decoded["mcpServers"]?["tacit"])
  #expect(mcp.command == config.command)
  #expect(mcp.args == config.args)
  #expect(model.otherMcp.arguments == "'/Users/sample/Library/Application Support/Tacit/runtime/hub/src/cli.ts' mcp --tool mcp")
}

@MainActor @Test func renderAgentSettingsSnapshots() throws {
  let tools: [AgentToolState] = [
    .init(id: "claude-code", label: "Claude Code", installed: true, connected: true, partial: false),
    .init(id: "codex", label: "Codex", installed: true, connected: true, partial: false),
    .init(id: "claude-desktop", label: "Claude Desktop", installed: false, connected: false, partial: false),
    .init(id: "antigravity", label: "Antigravity", installed: true, connected: false, partial: false),
  ]
  let output = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/ui-snapshots")
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

  for language: AppLanguage in [.zh, .en] {
    try AppLanguage.$scopedLanguage.withValue(language) {
      for scheme: ColorScheme in [.light, .dark] {
        let variant = "\(language == .zh ? "zh" : "en")-\(scheme == .light ? "light" : "dark")"
        @MainActor func render(_ name: String, _ content: some View) throws {
          let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
          renderer.scale = 2
          let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
          var image: CGImage?
          appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
          let bitmap = NSBitmapImageRep(cgImage: try #require(image))
          let data = try #require(bitmap.representation(using: .png, properties: [:]))
          try data.write(to: output.appendingPathComponent("\(name)-\(variant).png"))
        }

        try render("ai-tools", VStack(alignment: .leading, spacing: 12) {
          Text(L10n.Settings.aiTools).font(.system(size: TextSize.title, weight: .semibold))
          VStack(alignment: .leading, spacing: 12) {
            AgentToolRows(tools: tools, busy: nil, connect: { _ in }, showInstructions: {})
          }
          .padding(12).card()
          Note(L10n.Settings.toolsNote)
        }
        .font(.system(size: TextSize.body))
        .padding(20).frame(width: 560)
        .background(Palette.paper).tint(Palette.accent))

        try render("agent-instructions", AgentConnectionInstructions(config: config).background(Palette.paperRaised))
      }
    }
  }
}

@Test func automaticAgentConnectionActionCanCleanUpAnUninstalledTool() {
  let partial = AgentToolState(id: "antigravity", label: "Antigravity", installed: false, connected: false, partial: true)
  let installed = AgentToolState(id: "antigravity", label: "Antigravity", installed: true, connected: false, partial: true)
  let connected = AgentToolState(id: "antigravity", label: "Antigravity", installed: true, connected: true, partial: false)
  #expect(!partial.shouldConnect)
  #expect(installed.shouldConnect)
  #expect(!connected.shouldConnect)
}
