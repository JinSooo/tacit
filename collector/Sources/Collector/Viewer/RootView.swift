import AppKit
import SwiftUI
import CollectorCore

struct RootView: View {
  @Environment(ViewerStore.self) private var store
  @AppStorage("viewer.sidebarVisible") private var sidebarVisible = true

  private var columnVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly })
  }

  private var sidebarAction: String { sidebarVisible ? L10n.hideSidebar : L10n.showSidebar }

  var body: some View {
    @Bindable var store = store
    let section = store.section
    NavigationSplitView(columnVisibility: columnVisibility) {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 300)
    } detail: {
      NavigationStack(path: $store.path) {
        page(section)
          .toolbar { sidebarToggle }
          .navigationDestination(for: Route.self) { route in
            destination(route).toolbar { sidebarToggle }
          }
      }
    }
    .toolbar(removing: .sidebarToggle)
    .alert(L10n.removeProjectPrompt(store.projectToRemove?.name ?? ""),
           isPresented: Binding(get: { store.projectToRemove != nil }, set: { if !$0 { store.projectToRemove = nil } }),
           presenting: store.projectToRemove) { project in
      Button(L10n.remove, role: .destructive) { Task { await store.confirmProjectRemoval(project) } }
      Button(L10n.cancel, role: .cancel) {}
    } message: { _ in
      Text(L10n.projectRemovalExplanation)
    }
    .background(BehindWindowMaterial().ignoresSafeArea())
    .tint(Palette.accent)
    .accentColor(Palette.accent)
    .task {
      while !Task.isCancelled {
        store.refreshCapture()
        await WindowVisibility.pause(.seconds(2))
      }
    }
    .task {
      while !Task.isCancelled {
        await store.refreshShared()
        await WindowVisibility.pause(.seconds(60))
      }
    }
  }

  // 导航栈切换页面时会替换工具栏。根页和推入的详情都保留此项，避免标题栏高度变化。
  private var sidebarToggle: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      // 侧栏开合交给系统自己的分栏动画；再套一层 SwiftUI 动画会逐帧重排整页。
      Button { sidebarVisible.toggle() } label: { PhIcon("sidebar-simple", size: PhIcon.toolbar) }
        .help(sidebarAction)
        .accessibilityLabel(sidebarAction)
        .accessibilityValue(sidebarVisible ? L10n.expanded : L10n.collapsed)
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
  }

  @ViewBuilder private func page(_ section: Page) -> some View {
    switch section {
    case .review: ReviewPage()
    case .search: TimelineSearchPage()
    case .settings: SettingsPage()
    case .project(let id): ProjectPage(id: id).id(id)
    }
  }

  @ViewBuilder private func destination(_ route: Route) -> some View {
    switch route {
    case .thread(let id): ThreadPage(id: id)
    case .project(let id): ProjectPage(id: id)
    case .threadStory(let id): ThreadStoryPage(id: id)
    case .reviewItem(let day, let id): ReviewItemPage(day: day, id: id)
    case .reviewRecord(let id):
      RecordInspector(id: id) { _ in
        if store.path.last == .reviewRecord(id) { store.path.removeLast() }
      }
      .navigationTitle("")
      .toolbar { BackButton() }
    case .runtime: RuntimePage().toolbar { BackButton() }
    }
  }
}

struct Sidebar: View {
  @Environment(ViewerStore.self) private var store
  @AppStorage("viewer.projectsExpanded") private var projectsExpanded = true
  @State private var olderExpanded = false

  var body: some View {
    let (recent, older) = Project.byRecency(store.projects, now: .now)
    List(selection: Binding(get: { store.section }, set: { if let s = $0 { store.section = s } })) {
      Section {
        SidebarLabel(title: L10n.timeline, icon: "clock-counter-clockwise").tag(Page.review)
        SidebarLabel(title: L10n.search, icon: "magnifying-glass").tag(Page.search)
      }
      if !store.projects.isEmpty {
        Section(L10n.project, isExpanded: $projectsExpanded) {
          ForEach(recent) { projectRow($0) }
          if !older.isEmpty {
            // 一周没有活动的收进“更早”，有新活动自动回到上面；选中的项目在里面时保持展开。
            // 和项目行同一列对齐（系统折叠组的箭头会顶到最左、内容再缩一层，看着像另一种控件）。
            let open = olderExpanded || older.contains { store.section == .project($0.id) }
            Button { Motion.animate { olderExpanded = !open } } label: {
              Label {
                Text(L10n.earlier).lineLimit(1)
              } icon: {
                DisclosureChevron(expanded: open, size: 16, sideways: true).frame(width: 16)
              }
                .foregroundStyle(Palette.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { ForEach(older) { projectRow($0).transition(.reveal) } }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        if let error = store.projectRemovalError {
          Text(error).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention)
            .padding(.horizontal, 12)
            .transition(.notice)
        }
        CaptureFooter()
      }
      .animation(Motion.standard, value: store.projectRemovalError)
    }
  }

  // 还没确认的项目用虚线文件夹，和待确认里"新项目"同一个图标。
  private func projectRow(_ p: Project) -> some View {
    SidebarLabel(title: p.name, icon: p.confirmed.value ? "folder" : "folder-dashed")
      .help(p.confirmed.value ? p.name : L10n.unconfirmedProject(p.name))
      .contextMenu {
        Button(L10n.removeProject, role: .destructive) { store.projectToRemove = p }
          .disabled(store.removingProject)
      }
      .tag(Page.project(p.id))
  }
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
    Group {
      if c.state == .noPermission {
        VStack(alignment: .leading, spacing: 4) {
          statusLabel
          HStack(spacing: 8) {
            control
            Spacer(minLength: 0)
            settingsButton
          }.padding(.leading, 20)
        }
      } else {
        HStack(spacing: 8) {
          statusLabel
          Spacer(minLength: 0)
          control
          settingsButton
        }
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 12)
    .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    .padding(.horizontal, 8)
    // 暂停、继续、出错：圆点、标题和按钮一起淡过去，不一下子全换掉。
    .animation(Motion.standard, value: c.state)
    .animation(Motion.standard, value: title)
    .animation(Motion.standard, value: subtitle)
    .animation(Motion.quick, value: store.section == .settings)
  }

  private var statusLabel: some View {
    let c = store.capture
    return HStack(spacing: 8) {
      Circle().fill(dot).frame(width: 8, height: 8).padding(.leading, 4)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: TextSize.body, weight: .semibold))
          .foregroundStyle(c.state == .noPermission ? Palette.attention : Palette.ink)
          .lineLimit(c.state == .noPermission ? nil : 1)
          .fixedSize(horizontal: false, vertical: true)
        if let subtitle {
          Text(subtitle).font(.system(size: TextSize.caption))
            .foregroundStyle(c.hubError != nil ? Palette.attention : Palette.muted)
            .lineLimit(c.state == .noPermission ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var settingsButton: some View {
    Button { store.showSettings() } label: { PhIcon("gear-six", size: 16).frame(width: 28, height: 28).contentShape(Rectangle()) }
      .buttonStyle(.plain)
      .foregroundStyle(store.section == .settings ? Palette.accent : Palette.muted)
      .help(L10n.Menu.settings).accessibilityLabel(L10n.Menu.settings)
  }

  @ViewBuilder var control: some View {
    switch store.capture.state {
    case .recording:
      Menu {
        Button(L10n.Menu.pauseHour) { store.perform(.pauseHour) }
        Button(L10n.Menu.pauseTomorrow) { store.perform(.pauseTomorrow) }
      } label: { PhIcon("pause-circle", size: 18).frame(width: 28, height: 28).contentShape(Rectangle()) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Palette.muted)
        .help(L10n.pauseRecording).accessibilityLabel(L10n.pauseRecording)
    case .paused:
      Button { store.perform(.resume) } label: { PhIcon("play", size: 16).frame(width: 28, height: 28).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(Palette.accent)
        .help(L10n.Menu.resume).accessibilityLabel(L10n.Menu.resume)
    case .noPermission:
      Button(L10n.grantAccess) { store.perform(.requestAX) }.buttonStyle(.accentLink).fixedSize()
    }
  }

  var dot: Color {
    if store.capture.sources.allSatisfy({ !$0.enabled }) { return Palette.faint }
    switch store.capture.state {
    case .recording, .noPermission: return Palette.attention
    case .paused: return Palette.faint
    }
  }
  /// 侧栏窄，“需要辅助功能权限”加上授权按钮放不下一行，会截断或从词中间折开（2026-11-25 虚拟机实测），
  /// 所以缺权限时标题只写“需要授权”，缺的是哪项放到下面一行。
  var title: String {
    let c = store.capture
    if c.state == .noPermission && c.sources.contains(where: \.enabled) { return L10n.permissionNeeded }
    return c.statusTitle
  }

  var subtitle: String? {
    let c = store.capture
    if c.hubError != nil { return L10n.cantReachBackgroundService }
    if c.queue > 0 { return L10n.Menu.queued(c.queue) }
    if c.state == .noPermission && c.sources.contains(where: \.enabled) { return L10n.accessibilityPermission }
    guard c.state == .recording else { return nil }
    let n = c.sources.filter(\.enabled).count
    return n == 0 ? L10n.allSourcesAreOff : L10n.sourceCount(n)
  }
}

/// Preserve the principal layout slot so primary actions stay trailing, including macOS 14.
struct QuietPageTitle: ViewModifier {
  private var titleSlot: some View { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
  func body(content: Content) -> some View {
    content.navigationTitle("")
      .toolbar {
        if #available(macOS 26.0, *) {
          ToolbarItem(placement: .principal) { titleSlot }.sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItem(placement: .principal) { titleSlot }
        }
      }
  }
}
