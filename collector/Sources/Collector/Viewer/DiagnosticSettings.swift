import AppKit
import SwiftUI
import enum CollectorCore.L10n
import enum CollectorCore.DiagnosticSummary

struct OpenLogsButton: View {
  var body: some View {
    Button(L10n.Settings.openLogsFolder) {
      NSWorkspace.shared.open(Config.load().dataDir.appendingPathComponent("logs", isDirectory: true))
    }
  }
}

struct DiagnosticSettingsRow: View {
  @Environment(ViewerStore.self) private var store
  @State private var showing = false

  var body: some View {
    SettingsRow {
      Button(L10n.Settings.previewAndCopy) { showing = true }
    } label: {
      Text(L10n.Settings.diagnostics)
      Text(L10n.Settings.diagnosticsNote)
        .font(.system(size: TextSize.caption))
        .foregroundStyle(Palette.muted)
    }
    .sheet(isPresented: $showing) { DiagnosticPreview(api: store.api) }
  }
}

private struct DiagnosticPreview: View {
  @Environment(\.dismiss) private var dismiss
  @State private var summary: String?
  @State private var copied = false
  let api: HubAPI

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.Settings.diagnostics).font(.system(size: TextSize.title, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Group {
        if let summary {
          ScrollView {
            Text(verbatim: summary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .textSelection(.enabled)
          }
          .accessibilityLabel(L10n.Settings.diagnosticsPreview)
          .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control))
        } else {
          ProgressView()
            .accessibilityLabel(L10n.Settings.loadingDiagnostics)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(height: 300)
      HStack(spacing: 12) {
        OpenLogsButton()
        Spacer()
        Button(L10n.Settings.close) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(copied ? L10n.Settings.copied : L10n.Settings.copy) {
          guard let summary else { return }
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          copied = pasteboard.setString(summary, forType: .string)
          // 1.5 秒后复原，再按还能复制，和记录详情的复制一致。
          Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .disabled(summary == nil)
        .keyboardShortcut(.defaultAction)
      }
    }
    .font(.system(size: TextSize.body))
    .padding(20)
    .frame(width: 540)
    .tint(Palette.accent)
    .task { await load() }
  }

  private func load() async {
    let result = await api.diagnosticStatus()
    guard !Task.isCancelled else { return }
    let dataDir = Config.load().dataDir
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = L10n.Settings.unknownArchitecture
    #endif
    let text = await Task.detached(priority: .utility) {
      DiagnosticSummary.make(dataDir: dataDir, hubReachable: result.reachable, hubStatus: result.status,
                             version: version, build: build, macOSVersion: os, architecture: architecture)
    }.value
    if !Task.isCancelled { summary = text }
  }
}
