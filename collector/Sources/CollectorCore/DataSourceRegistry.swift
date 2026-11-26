import Foundation

/// 统一的数据源接口：屏幕、OCR、剪贴板、录音、文件、日历和各插件都按这个注册（AGENTS.md）。
/// 停用的数据源不启动、不读取，也不申请它的权限。
public protocol DataSource: AnyObject {
  var descriptor: DataSourceDescriptor { get }
  /// 需要的系统权限名称；不需要时为 nil。
  var permissionName: String? { get }
  /// 只查询，不弹授权框。
  var permission: SourcePermission { get }
  func requestPermission()
  /// 启动时（已启用，userInitiated=false）和用户打开开关时（true）调用：申请缺的权限、做首次启动。
  func didEnable(userInitiated: Bool)
  /// active = 已启用且没有暂停。false 时停止读取。
  func apply(active: Bool)
  var lastRun: Date? { get }
  var canRunNow: Bool { get }
  func runNow()
  /// 状态文字和是否正常。
  var detail: (text: String, ok: Bool) { get }
  var running: Bool { get }
}

extension DataSource {
  public var running: Bool { false }
}

/// 用闭包拼出来的数据源：采集逻辑仍在各自的采集器里，这里只把它们接到统一接口上。
public final class BlockSource: DataSource {
  public let descriptor: DataSourceDescriptor
  public var permissionName: String?
  public var permissionCheck: () -> SourcePermission = { .notNeeded }
  public var request: () -> Void = {}
  public var onEnable: (_ userInitiated: Bool) -> Void = { _ in }
  public var onApply: (Bool) -> Void = { _ in }
  public var last: () -> Date? = { nil }
  public var run: (() -> Void)?
  public var describe: () -> (text: String, ok: Bool) = { ("", true) }

  public init(_ id: String, configure: (BlockSource) -> Void = { _ in }) {
    descriptor = DataSourceCatalog.descriptor(id)!
    configure(self)
  }
  public var permission: SourcePermission { permissionCheck() }
  public func requestPermission() { request() }
  public func didEnable(userInitiated: Bool) { onEnable(userInitiated) }
  public func apply(active: Bool) { onApply(active) }
  public var lastRun: Date? { last() }
  public var canRunNow: Bool { run != nil }
  public func runNow() { run?() }
  public var detail: (text: String, ok: Bool) { describe() }
}

/// 注册表：按 DataSourceCatalog 的顺序持有全部数据源，开关持久化在 SourceToggles 里。
public final class DataSourceRegistry {
  public let toggles: SourceToggles
  public private(set) var sources: [DataSource] = []

  public init(toggles: SourceToggles) { self.toggles = toggles }

  public func register(_ item: DataSource) {
    precondition(source(item.descriptor.id) == nil, "数据源重复注册：\(item.descriptor.id)")
    sources.append(item)
    let order = DataSourceCatalog.all.map(\.id)
    sources.sort { (order.firstIndex(of: $0.descriptor.id) ?? .max) < (order.firstIndex(of: $1.descriptor.id) ?? .max) }
  }

  public func unregister(_ id: String) {
    source(id)?.apply(active: false)
    sources.removeAll { $0.descriptor.id == id }
  }

  public func source(_ id: String) -> DataSource? { sources.first { $0.descriptor.id == id } }
  public func isEnabled(_ id: String) -> Bool { toggles.isEnabled(id) }

  /// 启动时：已启用的数据源申请缺的权限并开始；停用的什么都不做。
  public func launch(paused: Bool) {
    for s in sources where isEnabled(s.descriptor.id) { s.didEnable(userInitiated: false) }
    applyAll(paused: paused)
  }

  public func setEnabled(_ id: String, _ on: Bool, paused: Bool) {
    guard let s = source(id), isEnabled(id) != on else { return }
    toggles.setEnabled(id, on)
    if on { s.didEnable(userInitiated: true) }
    s.apply(active: on && !paused)
  }

  public func applyAll(paused: Bool) {
    for s in sources { s.apply(active: isEnabled(s.descriptor.id) && !paused) }
  }

  public func statuses() -> [DataSourceStatus] {
    sources.map { s in
      let d = s.descriptor, on = isEnabled(d.id)
      // 停用的数据源不探测权限（浏览器的探测要打开文件）。
      let permission: SourcePermission = on ? s.permission : .notNeeded
      let detail = on ? s.detail : (text: L10n.text(zh: "已停用", en: "Disabled"), ok: true)
      return DataSourceStatus(id: d.id, title: d.title, kind: d.kind, enabled: on, permission: permission,
        permissionName: s.permissionName, lastRun: on ? s.lastRun : nil, detail: detail.text, ok: detail.ok,
        canRunNow: on && s.canRunNow, running: on && s.running)
    }
  }
}
