import Foundation

/// Leases cover operations through their last receipt or local side effect. Capture can still
/// enqueue records while the backend is paused. The coordinator holds the pause through publication.
public final class RemoteSwitchWriteGate: @unchecked Sendable {
  public struct Paused: LocalizedError {
    public var errorDescription: String? {
      L10n.text(zh: "正在切换后台，新的写入暂缓。", en: "Saving is paused while the background service switches.")
    }
  }

  public init() {}

  private let lock = NSLock()
  private var paused = false
  private var returning = false
  private var active = 0

  public func begin() throws {
    try lock.withLock {
      guard !paused else { throw Paused() }
      active += 1
    }
  }

  public func end() { lock.withLock { active -= 1 } }
  public func setPaused(_ paused: Bool) { lock.withLock { self.paused = paused } }
  public var isPaused: Bool { lock.withLock { paused } }
  public func setReturning(_ returning: Bool) { lock.withLock { self.returning = returning } }
  public var isReturning: Bool { lock.withLock { returning } }
  public var isIdle: Bool { lock.withLock { active == 0 } }
}
