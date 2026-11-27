import AppKit
@testable import CollectorCore
import SwiftUI
import Testing
@testable import Collector

@MainActor @Test func renderAgentSettingsSnapshots() throws {
  let cursor = AgentToolState(id: "cursor", label: "Cursor", installed: true, connected: false, partial: false, manual: [
    .init(file: "~/.cursor/mcp.json", kind: .mcp, action: .create, section: nil, code: """
    {
      "mcpServers": {
        "tacit": {
          "type": "stdio",
          "command": "/opt/homebrew/bin/bun",
          "args": ["/Users/sample/Library/Application Support/Tacit/runtime/hub/src/cli.ts", "mcp", "--tool", "cursor"]
        }
      }
    }
    """),
    .init(file: "~/.cursor/hooks.json", kind: .sessionStart, action: .add, section: "hooks.sessionStart", code: """
    {
      "command": "/opt/homebrew/bin/bun '/Users/sample/Library/Application Support/Tacit/runtime/hub/src/cli.ts' hook session-start --tool cursor",
      "timeout": 5
    }
    """),
  ])
  let opencode = AgentToolState(id: "opencode", label: "OpenCode", installed: false, connected: false, partial: false, manual: [
    .init(file: "~/.config/opencode/opencode.json", kind: .mcp, action: .create, section: nil, code: """
    {
      "mcp": {
        "tacit": {
          "type": "local",
          "command": [
            "/opt/homebrew/bin/bun",
            "/Users/sample/Tacit/runtime/hub/src/cli.ts",
            "mcp",
            "--tool",
            "opencode"
          ],
          "enabled": true
        }
      }
    }
    """),
  ])
  let copilot = AgentToolState(id: "copilot-cli", label: "Copilot CLI", installed: false, connected: false, partial: false, manual: [
    .init(file: "~/.copilot/mcp-config.json", kind: .mcp, action: .create, section: nil, code: """
    {
      "mcpServers": {
        "tacit": {
          "type": "local",
          "command": "/opt/homebrew/bin/bun",
          "args": [
            "/Users/sample/Tacit/runtime/hub/src/cli.ts",
            "mcp",
            "--tool",
            "copilot-cli"
          ],
          "tools": [
            "*"
          ]
        }
      }
    }
    """),
    .init(file: "~/.copilot/hooks/tacit.json", kind: .sessionStart, action: .create, section: nil, code: """
    {
      "version": 1,
      "hooks": {
        "sessionStart": [
          {
            "type": "command",
            "bash": "/opt/homebrew/bin/bun /Users/sample/Tacit/runtime/hub/src/cli.ts hook session-start --tool copilot-cli",
            "timeoutSec": 5
          }
        ]
      }
    }
    """),
  ])
  let tools: [AgentToolState] = [
    .init(id: "claude-code", label: "Claude Code", installed: true, connected: true, partial: false, manual: nil),
    .init(id: "codex", label: "Codex", installed: true, connected: true, partial: false, manual: nil),
    .init(id: "claude-desktop", label: "Claude Desktop", installed: false, connected: false, partial: false, manual: nil),
    .init(id: "antigravity", label: "Antigravity", installed: true, connected: false, partial: false, manual: nil),
    cursor,
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
            AgentToolRows(tools: tools, busy: nil, connect: { _ in }, showInstructions: { _ in })
          }
          .padding(12).card()
          Note(L10n.Settings.toolsNote)
        }
        .font(.system(size: TextSize.body))
        .padding(20).frame(width: 560)
        .background(Palette.paper).tint(Palette.accent))

        try render("agent-instructions", AgentConnectionInstructions(tool: cursor).background(Palette.paperRaised))
        if language == .zh && scheme == .light {
          try render("agent-instructions-opencode", AgentConnectionInstructions(tool: opencode).background(Palette.paperRaised))

          // SwiftUI 的 ImageRenderer 不会绘制 AppKit 承载的滚动内容。
          let appearance = try #require(NSAppearance(named: .aqua))
          let host = NSHostingView(rootView: AgentConnectionInstructions(tool: copilot)
            .background(Palette.paperRaised).environment(\.colorScheme, scheme))
          host.appearance = appearance
          host.frame = CGRect(origin: .zero, size: host.fittingSize)
          let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
          window.appearance = appearance
          window.contentView = host
          host.layoutSubtreeIfNeeded()
          let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
          window.contentView = nil
          let data = try #require(bitmap.representation(using: .png, properties: [:]))
          try data.write(to: output.appendingPathComponent("agent-instructions-copilot-cli-\(variant).png"))
        }
      }
    }
  }
}
