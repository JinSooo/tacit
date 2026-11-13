import AppKit
import AVFoundation
import EventKit
import CollectorCore

/// 外部插件（plugins/<name>/main.ts），由 PluginScheduler 运行。
final class PluginSource: DataSource {
  let descriptor: DataSourceDescriptor
  let scheduler: PluginScheduler
  init(_ id: String, scheduler: PluginScheduler) {
    descriptor = DataSourceCatalog.descriptor(id)!
    self.scheduler = scheduler
  }
  init(_ plugin: ExtensionPlugin, scheduler: PluginScheduler) {
    descriptor = DataSourceDescriptor(id: plugin.id, title: plugin.manifest.name, defaultEnabled: false, kind: .plugin)
    self.scheduler = scheduler
  }
  /// 只有浏览器插件读受保护的位置（Safari 的历史库需要完全磁盘访问）。
  var permissionName: String? { descriptor.id == "browser" ? "完全磁盘访问" : nil }
  var permission: SourcePermission {
    guard descriptor.id == "browser" else { return .notNeeded }
    return SystemPermissions.safariHistoryReadable()
  }
  func requestPermission() { SystemPermissions.openPrivacyPane("Privacy_AllFiles") }
  func didEnable(userInitiated: Bool) {}
  func apply(active: Bool) { scheduler.setActive(descriptor.id, active) }
  var lastRun: Date? { scheduler.outcome(descriptor.id)?.at }
  var canRunNow: Bool { scheduler.available }
  func runNow() { scheduler.run([descriptor.id], since: nil) }
  var running: Bool { scheduler.isRunning(descriptor.id) }
  var detail: (text: String, ok: Bool) {
    if !scheduler.available { return ("找不到 bun 或安装目录，重新运行一次 install.sh", false) }
    if descriptor.id == "shell" && !ShellHookFile.installed { return ("~/.zshrc 里还没有记录钩子", false) }
    if running { return ("运行中…", true) }
    guard let o = scheduler.outcome(descriptor.id) else { return ("还没运行过", true) }
    return (o.text, o.ok)
  }
}

enum SystemPermissions {
  static func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
  }

  static func microphone() -> SourcePermission {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .notDetermined: return .notDetermined
    default: return .denied
    }
  }
  static func requestMicrophone() {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
    else { openPrivacyPane("Privacy_Microphone") }
  }

  static func calendar() -> SourcePermission {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return .granted
    case .notDetermined: return .notDetermined
    default: return .denied
    }
  }

  /// 没有公开的完全磁盘访问查询接口：尝试打开 Safari 历史库（不读内容，立刻关闭）。没装 Safari 历史时视为不需要。
  static func safariHistoryReadable() -> SourcePermission {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db").path
    let fd = open(path, O_RDONLY)
    if fd >= 0 { close(fd); return .granted }
    return errno == ENOENT ? .notNeeded : .denied
  }
}


/// ~/.zshrc 上的读写。是软链接（dotfiles 管理）时改它指向的文件，保留原来的权限。
enum ShellHookFile {
  static var url: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    return home.resolvingSymlinksInPath()
  }
  static var installed: Bool { (try? String(contentsOf: url, encoding: .utf8)).map(ShellHook.installed) ?? false }

  static func set(_ on: Bool, repo: String?) throws {
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let next: String
    if on {
      guard let repo else { throw HookError.noRepo }
      next = ShellHook.adding(to: text, repo: repo)
    } else {
      next = ShellHook.removing(from: text)
    }
    guard next != text else { return }
    let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
    try next.write(to: url, atomically: true, encoding: .utf8)
    if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
  }

  enum HookError: LocalizedError {
    case noRepo
    var errorDescription: String? { "找不到 record-anything 的安装目录，重新运行一次 install.sh 再试。" }
  }
}
