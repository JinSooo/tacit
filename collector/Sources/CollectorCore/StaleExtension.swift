import Foundation

/// 升级后系统仍把小组件交给旧版扩展进程，版本对不上就一直重绘失败、停在旧画面。
public enum StaleExtension {
  public struct Process: Equatable, Sendable {
    public let pid: Int32
    public let path: String
    public let started: Date

    public init(pid: Int32, path: String, started: Date) {
      self.pid = pid
      self.path = path
      self.started = started
    }
  }

  /// 早于可执行文件落盘（ctime；拷贝会保留 mtime）启动的进程，跑的一定是被替换掉的旧版本。
  public static func pids(among processes: [Process], executable: String, installedAt: Date) -> [Int32] {
    processes.filter { $0.path == executable && $0.started < installedAt }.map(\.pid)
  }
}
