import Foundation
import Testing
@testable import CollectorCore

@Test func audioBoundaryCombinesTracksAndIncludesSixtySeconds() {
  var boundary = ConversationBoundary()
  let first = boundary.observe(start: t0, end: t0.addingTimeInterval(5)); #expect(!first)
  let other = boundary.observe(start: t0.addingTimeInterval(64.9), end: t0.addingTimeInterval(70)); #expect(!other)
  // 另一条轨道倒序到达，不能让最后人声时间倒退。
  let late = boundary.observe(start: t0.addingTimeInterval(20), end: t0.addingTimeInterval(30)); #expect(!late)
  #expect(!boundary.shouldClose(at: t0.addingTimeInterval(129.9)))
  let split = boundary.observe(start: t0.addingTimeInterval(130), end: t0.addingTimeInterval(131)); #expect(split)
  boundary.reset(); #expect(!boundary.shouldClose(at: t0.addingTimeInterval(1000)))
}
@Test func audioMetadataRoundTripAndStateOwnership() throws {
  var meta = AudioMetadata(start: t0)
  let json = try JSONSerialization.jsonObject(with: meta.encoded()) as! [String: Any]
  #expect(json["t_end"] is NSNull)
  #expect(try AudioMetadata.decode(meta.encoded()) == meta)
  #expect(throws: AudioError.self) { try meta.transition(to: .done, at: t0) }
  #expect(throws: AudioError.self) { try meta.transition(to: .closed, at: t0) }
  meta.segments = [AudioSegment(file: "mic-0001.enc", track: .mic, start: t0, end: t0.addingTimeInterval(2), dbfs: -30)]
  meta.t_end = LocalTime.iso(t0.addingTimeInterval(2))
  try meta.transition(to: .closed, at: t0)
  try meta.transition(to: .waiting_me, at: t0)
  for _ in 0..<3 { try meta.transition(to: .failed, at: t0, error: "合成错误") }
  #expect(throws: AudioError.self) { try meta.transition(to: .failed, at: t0, error: "合成错误") }
  #expect(try AudioMetadata.decode(meta.encoded()).attempts == 3)
}
@Test func retentionAndPurgeKeepOpenAndBoundary() throws {
  var meta = AudioMetadata(start: t0)
  let now = t0.addingTimeInterval(8 * 86400)
  #expect(!AudioPolicy.shouldDelete(meta, now: now, retentionDays: 7, purgeBefore: now))
  meta.t_end = LocalTime.iso(t0.addingTimeInterval(86400)); try meta.transition(to: .closed, at: t0)
  #expect(!AudioPolicy.shouldDelete(meta, now: now, retentionDays: 7))
  #expect(AudioPolicy.shouldDelete(meta, now: now.addingTimeInterval(1), retentionDays: 7))
  #expect(AudioPolicy.shouldDelete(meta, now: now, retentionDays: 365, purgeBefore: now))
}
@Test func microphoneWarningRequiresContinuousTenMinutesAndResetsOnPause() {
  var health = MicrophoneHealth()
  health.observe(dbfs: -80, start: t0, end: t0.addingTimeInterval(599), enabled: true)
  #expect(!health.warning)
  health.observe(dbfs: -80, start: t0.addingTimeInterval(599), end: t0.addingTimeInterval(600), enabled: true)
  #expect(health.warning)
  health.observe(dbfs: -70, start: t0, end: t0, enabled: true); #expect(!health.warning)
  health.observe(dbfs: -100, start: t0, end: t0.addingTimeInterval(600), enabled: false); #expect(!health.warning)
}

// 用户报告：录音收进来了，历史记录里却没有。两次连着问时第二次落在扫描冷却里答"没有"，转写进程一直没启动。
@Test func pendingWorkScanKeepsAnswerBetweenScans() {
  var scan = PendingWorkScan()
  var scans = 0
  let t = Date(timeIntervalSince1970: 1_000)
  #expect(scan.check(at: t) { scans += 1; return true })
  #expect(scan.check(at: t) { scans += 1; return false })
  #expect(scan.check(at: t.addingTimeInterval(59)) { scans += 1; return false })
  #expect(scans == 1)
  #expect(!scan.check(at: t.addingTimeInterval(60)) { scans += 1; return false })
  scan.invalidate()
  #expect(scan.check(at: t.addingTimeInterval(61)) { scans += 1; return true })
  #expect(scans == 3)
}
