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
          .toolbar { if needsAnchor { ToolbarAnchor() } }
          .navigationDestination(for: Route.self) { route in
            switch route {
            case .thread(let id): ThreadPage(id: id)
            case .project(let id): ProjectPage(id: id)
            }
          }
      }
    }
    .background(BehindWindowMaterial().ignoresSafeArea())
    .tint(Palette.accent)
    .accentColor(Palette.accent)
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

  /// 只有本身没有工具栏项的页面才放占位：占位项也占一格间距，放在别的页面上会把标题和按钮推开 8pt。
  var needsAnchor: Bool {
    switch store.section {
    case .settings, .project: return true
    default: return false
    }
  }

  @ViewBuilder var page: some View {
    switch store.section {
    case .review: ReviewPage()
    case .history: HistoryPage()
    case .pending: PendingPage()
    case .audit: RuntimePage()
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
        SidebarLabel(title: "回顾", icon: "sun-horizon").tag(Page.review)
        SidebarLabel(title: "历史记录", icon: "clock-counter-clockwise").tag(Page.history)
        // badge 必须在 tag 之前：放在 tag 之后，这一行在 macOS 侧栏里选不中。
        SidebarLabel(title: "待确认", icon: "tray")
          .badge(store.pending.count)
          .tag(Page.pending)
        SidebarLabel(title: "运行记录", icon: "eye").tag(Page.audit)
      }
      if !store.projects.isEmpty {
        Section("项目") {
          // 还没确认的项目用虚线文件夹，和待确认里"新项目"同一个图标。
          ForEach(store.projects) { p in
            SidebarLabel(title: p.name, icon: p.confirmed.value ? "folder" : "folder-dashed")
              .help(p.confirmed.value ? p.name : "\(p.name)，还没确认")
              .tag(Page.project(p.id))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) { CaptureFooter() }
  }
}

/// 页面一个工具栏项都没有时（设置、从侧栏进的项目页），SwiftUI 会把整条工具栏拆掉，
/// 标题栏从 52pt 缩到 32pt，红绿灯和侧栏跟着跳。放一个看不见的固定项让工具栏一直在。
/// 放在右侧：这两页右侧本来是空的，放左侧会把标题推开。
struct ToolbarAnchor: ToolbarContent {
  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .primaryAction) { anchor }.sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .primaryAction) { anchor }
    }
  }
  var anchor: some View { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
}

/// 侧栏默认图标偏大，压到和正文差不多的视觉重量。
struct SidebarLabel: View {
  let title: String
  let icon: String
  var body: some View {
    Label {
      Text(title).lineLimit(1)
    } icon: {
      PhIcon(icon, size: 16).frame(width: 16)
    }
  }
}

/// 侧边栏底部：采集状态，右边是暂停 / 继续和设置。
struct CaptureFooter: View {
  @Environment(ViewerStore.self) private var store

  var body: some View {
    let c = store.capture
    HStack(spacing: 8) {
      Circle().fill(dot).frame(width: 8, height: 8).padding(.leading, 4)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: TextSize.body, weight: .semibold))
          .foregroundStyle(c.state == .noPermission ? Palette.attention : Palette.ink)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle).font(.system(size: TextSize.caption))
            .foregroundStyle(c.hubError != nil ? Palette.attention : Palette.muted)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      control
      Button { store.section = .settings } label: { PhIcon("gear-six", size: 16).frame(width: 28, height: 28).contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .foregroundStyle(store.section == .settings ? Palette.accent : Palette.muted)
        .help("设置").accessibilityLabel("设置")
    }
    .padding(.horizontal, 8).padding(.vertical, 12)
    .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    .padding(.horizontal, 8)
  }

  @ViewBuilder var control: some View {
    switch store.capture.state {
    case .recording:
      Menu {
        Button("暂停 1 小时") { store.perform(.pauseHour) }
        Button("暂停到明天") { store.perform(.pauseTomorrow) }
      } label: { PhIcon("pause-circle", size: 18).frame(width: 28, height: 28).contentShape(Rectangle()) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Palette.muted)
        .help("暂停记录").accessibilityLabel("暂停记录")
    case .paused:
      Button { store.perform(.resume) } label: { PhIcon("play", size: 16).frame(width: 28, height: 28).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(Palette.accent)
        .help("继续记录").accessibilityLabel("继续记录")
    case .noPermission:
      Button("去授权…") { store.perform(.requestAX) }.buttonStyle(.accentLink)
    }
  }

  var dot: Color {
    switch store.capture.state {
    case .recording, .noPermission: return Palette.attention
    case .paused: return Palette.faint
    }
  }
  var title: String {
    switch store.capture.state {
    case .recording: return "正在记录"
    case .paused(let until): return "已暂停到 \(ViewerFormat.clock(until))"
    case .noPermission: return "需要辅助功能权限"
    }
  }
  var subtitle: String? {
    let c = store.capture
    if c.hubError != nil { return "连不上后台服务" }
    if c.queue > 0 { return "\(Fmt.count(c.queue)) 条记录等待保存" }
    guard c.state == .recording else { return nil }
    let n = c.sources.filter(\.enabled).count
    return n == 0 ? "所有数据源都已关闭" : "\(n) 个数据源"
  }
}
