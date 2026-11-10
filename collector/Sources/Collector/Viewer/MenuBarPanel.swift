import AppKit
import SwiftUI
import CollectorCore

/// 菜单栏左键弹出的面板：采集状态和暂停、此刻在做什么、近 1 小时的活动条、最近 5 条记录、待确认和打开主窗口。
/// 右键仍是原来的完整菜单。只读同机中枢的接口，不额外调用模型。
struct MenuBarPanel: View {
  static let width: CGFloat = 360
  /// 活动条覆盖的时长。
  static let window: TimeInterval = 3600
  /// 往前多取几小时：接口按开始时间过滤，开始得早、仍在进行的长片段也要画进活动条。
  static let lookback: TimeInterval = 6 * 3600

  @Environment(ViewerStore.self) private var store
  let open: (Page) -> Void
  /// 内容高度变化时通知面板窗口跟着调整。
  let onSize: (CGSize) -> Void
  @State private var now = Loader<NowState?>()
  @State private var hour = Loader<[HistoryRecord]>()
  @State private var recent = Loader<[HistoryRecord]>()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      status.padding(.horizontal, 16).padding(.vertical, 14)
      Divider()
      VStack(alignment: .leading, spacing: 16) {
        nowText
        hourStrip
      }
      .padding(16)
      Divider()
      recentList.padding(.vertical, 6)
      Divider()
      footer.padding(.horizontal, 10).padding(.vertical, 8)
    }
    .frame(width: Self.width)
    .background(Palette.paper)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    .task {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(for: .seconds(30))
      }
    }
    .task {
      while !Task.isCancelled {
        store.refreshCapture()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func load() async {
    let api = store.api
    let date = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    async let a: Void = now.run { try await api.now() }
    let from = iso.string(from: date.addingTimeInterval(-Self.lookback)), since = date.addingTimeInterval(-Self.window)
    async let b: Void = hour.run {
      var q = HubAPI.RecordQuery(); q.from = from; q.limit = 500
      return try await api.records(q, cursor: nil).records.filter { ($0.end ?? $0.start) >= since }
    }
    async let c: Void = recent.run {
      var q = HubAPI.RecordQuery(); q.limit = 5; q.body = true
      return try await api.records(q, cursor: nil).records
    }
    async let d: Void = store.refreshShared()
    _ = await (a, b, c, d)
  }

  // MARK: 状态

  var status: some View {
    let c = store.capture
    return HStack(spacing: 10) {
      Circle().fill(dot).frame(width: 9, height: 9)
        .overlay { if c.state == .recording { Circle().stroke(dot.opacity(0.3), lineWidth: 4) } }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold))
        if let subtitle {
          Text(subtitle).font(.system(size: 11)).foregroundStyle(c.hubError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      switch c.state {
      case .recording:
        Menu {
          Button("暂停 1 小时") { store.perform(.pauseHour) }
          Button("暂停到明天") { store.perform(.pauseTomorrow) }
        } label: {
          Text("暂停")
        }
        .menuStyle(.borderedButton).fixedSize().controlSize(.small)
      case .paused:
        Button("继续记录") { store.perform(.resume) }.controlSize(.small)
      case .noPermission:
        Button("授权…") { store.perform(.requestAX) }.controlSize(.small)
      }
    }
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
  /// 只说发送异常和录音状态。
  var subtitle: String? {
    let c = store.capture
    if let e = c.hubError { return e }
    if c.queue > 0 { return "待发送 \(c.queue) 条" }
    return c.recordingEnabled ? c.audio.first : nil
  }

  // MARK: 此刻

  @ViewBuilder var nowText: some View {
    Button { open(.now) } label: {
      VStack(alignment: .leading, spacing: 5) {
        if let state = now.value {
          Text(state?.brief?.isEmpty == false ? state!.brief! : "还没有当前摘要")
            .font(.serif(15)).lineSpacing(3).foregroundStyle(Palette.ink)
            .lineLimit(4).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          if let at = state?.updatedAt.flatMap(ViewerTime.parse) {
            Text("提炼于 \(ViewerFormat.relative(at))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
          }
        } else if let e = now.error {
          Text(e).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
        } else {
          RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.06)).frame(height: 40)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: 近 1 小时

  var hourStrip: some View {
    TimelineView(.everyMinute) { ctx in
      let range = ctx.date.addingTimeInterval(-Self.window)...ctx.date
      let rows = hour.value ?? []
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text("近 1 小时").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
          Spacer()
          if hour.value != nil {
            Text(rows.isEmpty ? "没有记录" : "\(rows.count) 条 · 活跃 \(ViewerFormat.compact(ActiveTime.seconds(rows, within: range)))")
              .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
          }
        }
        HourBar(records: rows, range: range)
      }
    }
  }

  // MARK: 最近记录

  @ViewBuilder var recentList: some View {
    if let rows = recent.value {
      if rows.isEmpty {
        Text("还没有记录").font(.system(size: 12)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 60)
      } else {
        VStack(spacing: 0) {
          ForEach(rows) { r in
            RecentRow(record: r) {
              store.showRecord(r.id, at: r.start)
              open(.history)
            }
          }
        }
        .padding(.horizontal, 6)
      }
    } else if let e = recent.error {
      Text(e).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3).padding(.horizontal, 16).padding(.vertical, 12)
    } else {
      // 占住大致高度，读完后面板不会突然变高一大截。
      Color.clear.frame(height: 5 * RecentRow.height)
    }
  }

  // MARK: 底部

  var footer: some View {
    HStack(spacing: 2) {
      if !store.pending.isEmpty {
        Button { open(.pending) } label: {
          HStack(spacing: 5) {
            PhIcon("tray", size: 14)
            Text("待确认 \(store.pending.count)")
          }
        }
        .buttonStyle(PanelButtonStyle())
      }
      Spacer()
      Button { open(.settings) } label: { PhIcon("gear-six", size: 15) }
        .buttonStyle(PanelButtonStyle()).help("设置").accessibilityLabel("设置")
      Button { open(.now) } label: {
        HStack(spacing: 5) {
          PhIcon("arrow-up-right", size: 13)
          Text("打开")
        }
      }
      .buttonStyle(PanelButtonStyle()).help("打开 Record Anything").keyboardShortcut("o")
    }
    .font(.system(size: 12))
  }
}

/// 一条最近的记录：来源图标、标题、时间，下面一行正文开头。
struct RecentRow: View {
  /// 带正文的一行大约的高度，读取前占位用。
  static let height: CGFloat = 46
  let record: HistoryRecord
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 10) {
        SourceGlyph(source: record.source, app: record.contextText("app"), size: 18).padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(record.title.isEmpty ? SourceInfo.name(record.source) : record.title)
              .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Text(ViewerFormat.clock(record.start)).font(.mono(10.5)).foregroundStyle(.tertiary)
          }
          if let line = snippet {
            Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }

  /// 正文压成一行；没有正文时用网址的域名或所在目录。
  var snippet: String? {
    let text = (record.body ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ")
    if !text.isEmpty { return text }
    if let url = record.contextText("url").flatMap(URL.init(string:)), let host = url.host() { return host }
    return (record.contextText("repo") ?? record.contextText("cwd")).map { ($0 as NSString).abbreviatingWithTildeInPath }
  }
}

/// 近 1 小时的活动带：每条记录按来源上色，右端是现在。
struct HourBar: View {
  let records: [HistoryRecord]
  let range: ClosedRange<Date>

  var body: some View {
    let span = range.upperBound.timeIntervalSince(range.lowerBound)
    VStack(spacing: 3) {
      GeometryReader { geo in
        let w = geo.size.width
        let x = { (d: Date) in CGFloat(min(max(d.timeIntervalSince(range.lowerBound) / span, 0), 1)) * w }
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.06))
          ForEach(records) { r in
            let a = x(r.start), b = x(r.end ?? r.start)
            Rectangle().fill(Palette.source(r.source).opacity(0.85))
              .frame(width: max(1.5, b - a)).offset(x: a)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
      }
      .frame(height: 12)
      HStack {
        Text(ViewerFormat.clock(range.lowerBound))
        Spacer()
        Text(ViewerFormat.clock(range.lowerBound.addingTimeInterval(span / 2)))
        Spacer()
        Text("现在")
      }
      .font(.mono(9)).foregroundStyle(.tertiary)
    }
  }
}

enum ActiveTime {
  /// 并集时长：重叠的时段只算一次；给了 range 时只算落在其中的部分。
  static func seconds(_ rows: [HistoryRecord], within range: ClosedRange<Date>? = nil) -> TimeInterval {
    let spans = rows.compactMap { r -> (Date, Date)? in
      guard var e = r.end else { return nil }
      var s = r.start
      if let range { s = max(s, range.lowerBound); e = min(e, range.upperBound) }
      return e > s ? (s, e) : nil
    }.sorted { $0.0 < $1.0 }
    var total: TimeInterval = 0, cur: (Date, Date)?
    for s in spans {
      if let c = cur, s.0 <= c.1 { cur = (c.0, max(c.1, s.1)) }
      else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = s }
    }
    if let c = cur { total += c.1.timeIntervalSince(c.0) }
    return total
  }
}

struct PanelButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PanelButton(configuration: configuration)
  }
  struct PanelButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    var body: some View {
      configuration.label
        .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
  }
}

// MARK: 面板窗口

/// 无边框浮动面板，贴在菜单栏图标正下方。不用 NSPopover：它带箭头、离图标有一段空，
/// 盖不到全屏 App 上面，App 没激活时点别处也不会收起（2026-11-10 用户报告）。
/// 面板不激活 App（nonactivatingPanel），全屏 App 前也能弹出；点面板外、按 Esc、切换桌面都会收起。
@MainActor final class StatusPanel {
  private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }

  private let store: ViewerStore
  private let open: (Page) -> Void
  private var panel: Panel?
  private weak var button: NSStatusBarButton?
  private var monitors: [Any] = []
  private var spaceObserver: Any?
  /// 面板顶边和水平中心（屏幕坐标），内容变高时保持顶边不动。
  private var top: CGFloat = 0
  private var centerX: CGFloat = 0
  /// 菜单栏图标在屏幕上的位置。点在这里的鼠标事件交给图标自己（开关面板），不当成"点了面板外"。
  private var anchor: CGRect = .zero

  init(store: ViewerStore, open: @escaping (Page) -> Void) {
    self.store = store
    self.open = open
  }

  var isShown: Bool { panel?.isVisible == true }

  func toggle(from button: NSStatusBarButton) {
    if isShown { close() } else { show(from: button) }
  }

  func show(from button: NSStatusBarButton) {
    guard let anchorWindow = button.window else { return }
    self.button = button
    anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let p = panel ?? makePanel()
    panel = p
    // 每次打开都换新内容：重新读取，关掉后视图里的轮询随之停止。
    let content = MenuBarPanel(open: { [weak self] page in
      self?.close()
      self?.open(page)
    }, onSize: { [weak self] size in self?.resize(to: size) })
    let host = NSHostingView(rootView: AnyView(content.environment(store)))
    p.contentView = host
    top = anchor.minY - 6
    centerX = anchor.midX
    resize(to: host.fittingSize)
    p.makeKeyAndOrderFront(nil)
    button.highlight(true)
    installMonitors()
  }

  func close() {
    guard let p = panel, p.isVisible else { return }
    p.orderOut(nil)
    p.contentView = nil
    button?.highlight(false)
    for m in monitors { NSEvent.removeMonitor(m) }
    monitors = []
    if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); spaceObserver = nil }
  }

  private func makePanel() -> Panel {
    let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    p.isFloatingPanel = true
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.animationBehavior = .utilityWindow
    return p
  }

  private func resize(to size: CGSize) {
    guard let p = panel, size.width > 0, size.height > 0 else { return }
    var frame = CGRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    // 不超出图标所在屏幕的左右边。
    if let screen = button?.window?.screen ?? NSScreen.main {
      let bounds = screen.frame.insetBy(dx: 8, dy: 0)
      frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
    }
    p.setFrame(frame, display: true)
    p.invalidateShadow()
  }

  private func installMonitors() {
    guard monitors.isEmpty else { return }
    // 别的 App 里的点击。菜单栏图标的点击也可能从这里进来，同样交给图标自己。
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.anchor.contains(NSEvent.mouseLocation) else { return }
        self.close()
      }
    }) { monitors.append(m) }
    // 本 App 其他窗口里的点击、Esc。点菜单栏图标本身交给图标的点击处理（开关面板）。
    if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
      let isEscape = event.type == .keyDown && event.keyCode == 53
      let isKey = event.type == .keyDown
      let window = event.windowNumber
      let consume = MainActor.assumeIsolated { () -> Bool in
        guard let self else { return false }
        if isEscape { self.close(); return true }
        if !isKey, window != self.panel?.windowNumber, !self.anchor.contains(NSEvent.mouseLocation) { self.close() }
        return false
      }
      return consume ? nil : event
    }) { monitors.append(m) }
    spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
  }
}
