import Foundation

/// 同一数据目录只允许一个采集端在跑：两份同时运行会重复录音、重复采集。
/// 用 flock：进程退出（包括崩溃）时系统自动释放，不会留下过期的锁。
public final class InstanceLock {
  public enum Result { case acquired(InstanceLock), held, unavailable }
  private let fd: Int32
  private init(fd: Int32) { self.fd = fd }

  /// 锁文件打不开时返回 unavailable，由调用方照常启动（不能因为锁文件的问题停止记录）。
  public static func acquire(path: String) -> Result {
    // O_CLOEXEC：插件、转写这些子进程不继承锁，采集端退出后锁就释放。
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return .unavailable }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .acquired(InstanceLock(fd: fd)) }
    let busy = errno == EWOULDBLOCK
    close(fd)
    return busy ? .held : .unavailable
  }

  /// 一直等到拿到锁（正在运行的那份退出或崩溃）。锁文件打不开时返回 nil。
  public static func wait(path: String) -> InstanceLock? {
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    while flock(fd, LOCK_EX) != 0 {
      guard errno == EINTR else { close(fd); return nil }
    }
    return InstanceLock(fd: fd)
  }

  deinit { flock(fd, LOCK_UN); close(fd) }
}

/// 采集端正常退出（菜单里退出、系统关机注销）时留下的记号。
/// launchd 拉起的待命实例拿到锁后看到它就跟着退出；没有记号说明上一份是崩溃的，待命实例接手继续记录。
public enum CleanQuitMarker {
  static func file(in dataDir: URL) -> URL { dataDir.appendingPathComponent("collector-quit") }
  public static func mark(in dataDir: URL) { FileManager.default.createFile(atPath: file(in: dataDir).path, contents: Data()) }
  public static func clear(in dataDir: URL) { try? FileManager.default.removeItem(at: file(in: dataDir)) }
  public static func isMarked(in dataDir: URL) -> Bool { FileManager.default.fileExists(atPath: file(in: dataDir).path) }
}
