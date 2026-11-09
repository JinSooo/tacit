import Foundation
import Testing
@testable import CollectorCore

@Test func fileEventLossRequestsRebuildEvenWithExistingStream() {
  var recovery = FileStreamRecovery()
  recovery.startSucceeded()
  #expect(!recovery.shouldStart(now: 100, paused: false, hasStream: true))
  recovery.eventsDropped()
  #expect(recovery.needsRebuild && recovery.unavailable)
  #expect(recovery.shouldStart(now: 100, paused: false, hasStream: true))
  #expect(!recovery.recoveredFromDrop)
  recovery.startSucceeded()
  #expect(!recovery.needsRebuild && !recovery.unavailable)
  #expect(!recovery.shouldStart(now: 100, paused: false, hasStream: true))
  #expect(recovery.recoveredFromDrop)
  // 暂停后重新启动不应清掉恢复提示，只有产出新记录才清掉。
  recovery.startSucceeded()
  #expect(recovery.recoveredFromDrop)
  recovery.recordEmitted()
  #expect(!recovery.recoveredFromDrop)
}

@Test func fileStreamFailuresBackOffAndCapThenResetOnSuccess() {
  var recovery = FileStreamRecovery()
  var now: TimeInterval = 100
  #expect(recovery.shouldStart(now: now, paused: false, hasStream: false))
  for delay: TimeInterval in [5, 30, 300, 300, 300] {
    recovery.startFailed(now: now)
    #expect(recovery.unavailable && recovery.needsRebuild)
    #expect(recovery.retryDelay == delay)
    #expect(!recovery.shouldStart(now: now, paused: false, hasStream: false))
    #expect(!recovery.shouldStart(now: now + delay - 0.01, paused: false, hasStream: false))
    now += delay
    #expect(recovery.shouldStart(now: now, paused: false, hasStream: false))
  }
  recovery.startSucceeded()
  #expect(!recovery.unavailable && !recovery.needsRebuild)
  #expect(recovery.retryDelay == 0)
  #expect(!recovery.recoveredFromDrop)
  recovery.startFailed(now: now)
  #expect(recovery.retryDelay == 5)
  recovery.startSucceeded()
  #expect(recovery.shouldStart(now: now, paused: false, hasStream: false))
}

@Test func fileStreamPauseBlocksInitialStartRebuildAndExpiredRetry() {
  var recovery = FileStreamRecovery()
  #expect(!recovery.shouldStart(now: 0, paused: true, hasStream: false))
  recovery.startSucceeded()
  recovery.eventsDropped()
  #expect(!recovery.shouldStart(now: 10, paused: true, hasStream: true))
  #expect(!recovery.shouldStart(now: 10, paused: true, hasStream: false))
  recovery.startFailed(now: 10)
  #expect(!recovery.shouldStart(now: 14, paused: false, hasStream: false))
  #expect(!recovery.shouldStart(now: 15, paused: true, hasStream: false))
  #expect(recovery.shouldStart(now: 15, paused: false, hasStream: false))
  recovery.startSucceeded()
  #expect(recovery.recoveredFromDrop && !recovery.unavailable)
}

@Test func fileEventLossDiscardsPendingWithoutReplayingOldFiles() {
  var recovery = FileStreamRecovery()
  var buffer = FileAppearanceBuffer()
  let time = Date(timeIntervalSince1970: 1_800_000_000)
  func file(_ name: String, offset: Double) -> FileAppearance {
    FileAppearance(path: "/Users/synthetic/Downloads/\(name)", inode: 42, created: time,
      observed: time.addingTimeInterval(offset), size: 100, directory: "Downloads")
  }
  recovery.startSucceeded()
  buffer.append(file("丢失前.txt", offset: 0))
  recovery.eventsDropped()
  buffer.discardPending()
  recovery.startSucceeded()
  #expect(buffer.drain(now: time.addingTimeInterval(120), device: "test-mac", force: true).isEmpty)
  buffer.append(file("恢复后.txt", offset: 121))
  let records = buffer.drain(now: time.addingTimeInterval(181), device: "test-mac")
  #expect(records.count == 1)
  #expect(records.first?.title == "下载 · 恢复后.txt")
  #expect(recovery.recoveredFromDrop)
  if !records.isEmpty { recovery.recordEmitted() }
  #expect(!recovery.recoveredFromDrop)
}
