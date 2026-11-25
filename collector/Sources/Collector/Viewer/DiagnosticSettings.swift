import AppKit
import SwiftUI
import enum CollectorCore.DiagnosticSummary

struct OpenLogsButton: View {
  var body: some View {
    Button("打开日志文件夹") {
      NSWorkspace.shared.open(Config.load().dataDir.appendingPathComponent("logs", isDirectory: true))
    }
  }
}

struct DiagnosticSettingsRow: View {
  @Environment(ViewerStore.self) private var store
  @State private var showing = false

  var body: some View {
    SettingsRow {
      Button("预览并复制…") { showing = true }
    } label: {
      Text("诊断信息")
      Text("包含版本、运行状态和日志事件，不包含记录内容。")
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
      Text("诊断信息").font(.system(size: TextSize.title, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Group {
        if let summary {
          ScrollView {
            Text(verbatim: summary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .textSelection(.enabled)
          }
          .accessibilityLabel("诊断信息预览")
          .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control))
        } else {
          ProgressView()
            .accessibilityLabel("正在读取诊断信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(height: 300)
      HStack(spacing: 12) {
        OpenLogsButton()
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(copied ? "已复制" : "复制") {
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
    let architecture = "未知架构"
    #endif
    let text = await Task.detached(priority: .utility) {
      DiagnosticSummary.make(dataDir: dataDir, hubReachable: result.reachable, hubStatus: result.status,
                             version: version, build: build, macOSVersion: os, architecture: architecture)
    }.value
    if !Task.isCancelled { summary = text }
  }
}
