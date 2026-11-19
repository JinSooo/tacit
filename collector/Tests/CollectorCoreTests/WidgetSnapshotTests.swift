import Foundation
import XCTest
@testable import CollectorCore

final class WidgetSnapshotTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return value
  }

  func testSnapshotKeepsOnlyTodayAndTheThreeMostRecentTitles() throws {
    let now = try XCTUnwrap(ViewerTime.parse("2026-01-15T13:00:00+09:00"))
    let items = [
      ("08", "测量种植槽"), ("11", "核对标签"), ("09", "安排浇水"), ("10", "整理花盆"),
      ("invalid", "错误时刻"), ("yesterday", "昨天的记录"),
    ].map { hour, title -> [String: Any] in
      let start = hour == "yesterday" ? "2026-01-14T23:59:00+09:00" : "2026-01-15T\(hour):00:00+09:00"
      return ["id": hour, "title": title, "description": "仅主窗口展示的虚构细节",
              "t_start": start, "t_end": start, "active_seconds": 0, "sources": [], "evidence": [], "record_ids": ["fixture"]]
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "date": "2026-01-15", "detail": ["summary": "  整理了温室。 ", "items": items],
    ])
    let diary = try HubJSON.decoder().decode(DayDiary.self, from: data)
    let snapshot = WidgetSnapshot(diary: diary, now: now, calendar: calendar)

    XCTAssertEqual(snapshot.segments.map(\.title), ["核对标签", "整理花盆", "安排浇水"])
    XCTAssertEqual(snapshot.summary, "整理了温室。")
    let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    XCTAssertFalse(payload.contains("仅主窗口展示"))
    XCTAssertFalse(payload.contains("fixture"))
    XCTAssertTrue(WidgetSnapshot(diary: diary, now: now.addingTimeInterval(86_400), calendar: calendar).segments.isEmpty)
  }

  func testYesterdayFileIsUnreadableAsTodayAndURLRejectsInvalidDates() throws {
    let morning = try XCTUnwrap(ViewerTime.parse("2026-01-15T00:00:00+09:00"))
    let snapshot = WidgetSnapshot(day: "2026-01-15", summary: "温室改用分区浇水。")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("today.json")
    try JSONEncoder().encode(snapshot).write(to: file)

    XCTAssertEqual(WidgetSnapshot.readToday(from: file, now: morning, calendar: calendar), snapshot)
    XCTAssertNil(WidgetSnapshot.readToday(from: file, now: morning.addingTimeInterval(86_400), calendar: calendar))
    XCTAssertEqual(WidgetSnapshot.timelineDate(from: try XCTUnwrap(snapshot.timelineURL), calendar: calendar), morning)
    let invalid = ["2026-02-30", "2026-1-15", "2026-01-15&date=2026-01-16"]
    for date in invalid {
      XCTAssertNil(WidgetSnapshot.timelineDate(from: try XCTUnwrap(URL(string: "tacit://timeline?date=\(date)")), calendar: calendar))
    }
  }
}
