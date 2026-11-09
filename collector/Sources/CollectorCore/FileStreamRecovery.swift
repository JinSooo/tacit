import Foundation

/// 只决定监听恢复与重试时机；时间由调用方传入单调时钟，不受系统校时影响。
public struct FileStreamRecovery {
  public private(set) var needsRebuild = true
  public private(set) var unavailable = false
  public private(set) var recoveredFromDrop = false
  public private(set) var retryDelay: TimeInterval = 0
  private var retryAt: TimeInterval?
  private var pendingDrop = false

  public init() {}

  public func shouldStart(now: TimeInterval, paused: Bool, hasStream: Bool) -> Bool {
    !paused && (needsRebuild || !hasStream) && (retryAt.map { now >= $0 } ?? true)
  }

  public mutating func eventsDropped() {
    needsRebuild = true
    unavailable = true
    pendingDrop = true
  }

  public mutating func startFailed(now: TimeInterval) {
    needsRebuild = true
    unavailable = true
    retryDelay = retryDelay == 0 ? 5 : (retryDelay == 5 ? 30 : 300)
    retryAt = now + retryDelay
  }

  public mutating func startSucceeded() {
    needsRebuild = false
    unavailable = false
    recoveredFromDrop = recoveredFromDrop || pendingDrop
    pendingDrop = false
    retryDelay = 0
    retryAt = nil
  }

  public mutating func recordEmitted() { recoveredFromDrop = false }
}
