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

  deinit { flock(fd, LOCK_UN); close(fd) }
}
