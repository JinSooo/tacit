import AppKit
import SwiftUI
import CollectorCore

struct RootView: View {
  @Environment(ViewerStore.self) private var store

  var body: some View {
    @Bindable var store = store
    NavigationSplitView {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 300)
    } detail: {
      NavigationStack(path: $store.path) {
        page
          .navigationDestination(for: Route.self) { route in
            switch route {
            case .thread(let id): ThreadPage(id: id)
            case .project(let id): ProjectPage(id: id)
            }
          }
      }
    }
    .task {
      while !Task.isCancelled {
        store.refreshCapture()
        try? await Task.sleep(for: .seconds(2))
      }
    }
    .task {
      while !Task.isCancelled {
        await store.refreshShared()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  @ViewBuilder var page: some View {
    switch store.section {
    case .now: NowPage()
    case .history: HistoryPage()
    case .pending: PendingPage()
    case .audit: AuditPage()
    case .settings: SettingsPage()
    case .project(let id): ProjectPage(id: id).id(id)
    }
  }
}

struct Sidebar: View {
  @Environment(ViewerStore.self) private var store

  var body: some View {
    @Bindable var store = store
    List(selection: Binding(get: { store.section }, set: { if let s = $0 { store.section = s } })) {
      Section {
        SidebarLabel(title: "此刻", icon: "sun.horizon").tag(Page.now)
        SidebarLabel(title: "History", icon: "clock.arrow.circlepath").tag(Page.history)
        // badge 必须在 tag 之前：放在 tag 之后，这一行在 macOS 侧栏里选不中。
        SidebarLabel(title: "待确认", icon: "tray.full")
          .badge(store.pending.count)
          .tag(Page.pending)
        SidebarLabel(title: "读取记录", icon: "eye").tag(Page.audit)
      }
      if !store.projects.isEmpty {
        Section("项目") {
          ForEach(store.projects) { p in
            HStack(spacing: 8) {
              Circle().fill(Palette.tag(p.name)).frame(width: 8, height: 8).padding(.leading, 4)
              Text(p.name).lineLimit(1)
              Spacer(minLength: 4)
              if !p.confirmed.value { Image(systemName: "questionmark.circle").foregroundStyle(.tertiary).font(.caption) }
            }
            .tag(Page.project(p.id))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) { CaptureFooter() }
  }
}

/// 侧栏默认图标偏大，压到和正文差不多的视觉重量。
struct SidebarLabel: View {
  let title: String
  let icon: String
  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: icon).font(.system(size: 12, weight: .regular)).frame(width: 16)
    }
  }
}

/// 侧边栏底部：采集状态。点开是和菜单栏一样的暂停/继续。
struct CaptureFooter: View {
  @Environment(ViewerStore.self) private var store
  @State private var pulse = false

  var body: some View {
    let c = store.capture
    HStack(spacing: 10) {
      Menu {
        switch c.state {
        case .recording:
          Button("暂停 1 小时") { store.perform(.pauseHour) }
          Button("暂停到明天") { store.perform(.pauseTomorrow) }
        case .paused:
          Button("继续记录") { store.perform(.resume) }
        case .noPermission:
          Button("授权辅助功能…") { store.perform(.requestAX) }
        }
      } label: {
        HStack(spacing: 8) {
          ZStack {
            Circle().fill(dot.opacity(0.25)).frame(width: 14, height: 14).scaleEffect(pulse && c.state == .recording ? 1.5 : 0.8)
              .opacity(pulse && c.state == .recording ? 0 : 1)
            Circle().fill(dot).frame(width: 7, height: 7)
          }
          .frame(width: 14, height: 14)
          VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)

      Button { store.section = .settings } label: {
        Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 26, height: 26)
      }
      .buttonStyle(.plain)
      .foregroundStyle(store.section == .settings ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
      .help("设置")
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .glassPanel(14)
    .padding(10)
    .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
  }

  var dot: Color {
    switch store.capture.state {
    case .recording: return Palette.recording
    case .paused: return .secondary
    case .noPermission: return .orange
    }
  }
  var title: String {
    switch store.capture.state {
    case .recording: return "正在记录"
    case .paused(let until): return "已暂停到 \(ViewerFormat.clock(until))"
    case .noPermission: return "缺少辅助功能权限"
    }
  }
  var subtitle: String {
    let c = store.capture
    if let e = c.hubError { return e }
    if c.queue > 0 { return "待发送 \(c.queue) 条" }
    return c.recordingEnabled ? "屏幕 · 录音 · 数据源" : "屏幕 · 数据源"
  }
}

