import Foundation

/// 大目录扫描/清理由独立队列串行执行，重复请求不排队；完成回调回到状态所属队列。
public final class BackgroundMaintenance {
  private let work = DispatchQueue(label: "record-anything.audio-maintenance", qos: .utility)
  private let lock = NSLock()
  private var running = false
  public init() {}
  public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
  @discardableResult public func perform<T>(returningTo queue: DispatchQueue, operation: @escaping () throws -> T,
                                            completion: @escaping (Result<T, Error>) -> Void) -> Bool {
    lock.lock()
    guard !running else { lock.unlock(); return false }
    running = true; lock.unlock()
    work.async {
      let result = Result { try operation() }
      queue.async {
        self.lock.lock(); self.running = false; self.lock.unlock()
        completion(result)
      }
    }
    return true
  }
  /// 只能在 returningTo 队列外调用；随后让该队列处理完成回调。
  public func drain() { work.sync {} }
}
