import Foundation
import Testing
@testable import CollectorCore

@Test func textAreaTailDoesNotRetainCredentialTails() {
  #expect(Text.captureSuffix("说明 AKIA1234567890ABCDEF 后续内容", limit: 12) == " 后续内容")
  let key = "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "AbCd0123\n", count: 100) + "-----END PRIVATE KEY-----\n后续内容"
  #expect(Text.captureSuffix(key, limit: 100) == "\n后续内容")
}

@Test func ocrBacksOffWhileWindowTextStaysTheSame() {
  var schedule = OCRSchedule()
  let start = Date(timeIntervalSince1970: 1_000)
  func run(at seconds: TimeInterval, _ lines: [String]) -> Bool {
    let now = start.addingTimeInterval(seconds)
    guard schedule.due("w", now: now) else { return false }
    schedule.started("w", now: now); schedule.finished("w", lines: lines); return true
  }
  #expect(run(at: 0, ["a"]))
  #expect(!run(at: 15, ["a"]))
  #expect(run(at: 16, ["a"]))         // 第二次相同：间隔变 30 秒
  #expect(!run(at: 45, ["a"]))
  #expect(run(at: 47, ["a"]))         // 60 秒
  #expect(run(at: 108, ["a"]))        // 120 秒，到顶
  #expect(!run(at: 228, ["a"]))
  #expect(run(at: 229, ["b"]))        // 文字变了，回到 15 秒
  #expect(run(at: 245, ["b"]))
  #expect(schedule.due("other", now: start))
}
