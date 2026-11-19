import Foundation
import XCTest
@testable import CollectorCore

final class WidgetSnapshotTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return value
  }

  func testSnapshotKeepsAllOfTodaysSegmentsForTheActivityStrip() throws {
    let now = try XCTUnwrap(ViewerTime.parse("2026-01-15T13:00:00+09:00"))
    let items = [
      ("08", "测量种植槽"), ("11", "核对标签"), ("09", "安排浇水"), ("10", "整理花盆"),
      ("invalid", "错误时刻"), ("yesterday", "昨天的记录"),
    ].map { hour, title -> [String: Any] in
      let start = hour == "yesterday" ? "2026-01-14T23:59:00+09:00" : "2026-01-15T\(hour):00:00+09:00"
      let end = hour == "08" ? "2026-01-15T08:30:00+09:00" : "2026-01-15T14:00:00+09:00"
      return ["id": hour, "title": title, "description": "核对温室育苗计划。",
              "t_start": start, "t_end": end, "active_seconds": hour == "08" ? 1800 : 0,
              "sources": ["mac.browser", "mac.audio"],
              "apps": hour == "11" ? [["source": "mac.browser", "app": "com.example.Garden"], ["source": "mac.audio"]] : [],
              "evidence": [], "record_ids": ["fixture"]]
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "date": "2026-01-15", "detail": ["summary": "  整理了温室。 ", "items": items],
    ])
    let diary = try HubJSON.decoder().decode(DayDiary.self, from: data)
    let icon = String(repeating: "a", count: 64) + ".png"
    let snapshot = WidgetSnapshot(diary: diary, now: now, calendar: calendar) { app in
      XCTAssertEqual(app.source, "mac.browser")
      return app.app == "com.example.Garden" ? icon : nil
    }

    XCTAssertEqual(snapshot.segments.map(\.title), ["核对标签", "整理花盆", "安排浇水", "测量种植槽"])
    XCTAssertEqual(snapshot.summary, "整理了温室。")
    XCTAssertEqual(snapshot.segments.first?.description, "核对温室育苗计划。")
    XCTAssertEqual(snapshot.segments.map(\.source), Array(repeating: "mac.browser", count: 4))
    XCTAssertEqual(snapshot.segments.map(\.icon), [icon, nil, nil, nil])
    for segment in snapshot.segments.dropLast() { XCTAssertEqual(segment.start, segment.end) }
    let earliest = try XCTUnwrap(snapshot.segments.last)
    XCTAssertEqual(earliest.end.timeIntervalSince(earliest.start), 1800)
    XCTAssertEqual(snapshot.activityRange(at: now), earliest.start...now)
    let latest = try XCTUnwrap(snapshot.segments.first)
    XCTAssertEqual(snapshot.activityRange(at: earliest.start), earliest.start...latest.end)
    let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    XCTAssertFalse(payload.contains("fixture"))
    XCTAssertFalse(payload.contains("com.example.Garden"))
    XCTAssertTrue(WidgetSnapshot(diary: diary, now: now.addingTimeInterval(86_400), calendar: calendar).segments.isEmpty)
  }

  func testSnapshotDoesNotPublishLegacyDiaryWithoutEvidenceProvenance() throws {
    let data = Data("""
      {"date":"2026-01-15","detail":{"summary":"温室改用分区浇水。","items":[{
        "id":"fixture","title":"整理花盆","description":"分出育苗区",
        "t_start":"2026-01-15T08:00:00+09:00","t_end":"2026-01-15T08:30:00+09:00",
        "active_seconds":1800,"sources":["mac.browser"],"evidence":[]
      }]}}
      """.utf8)
    let diary = try HubJSON.decoder().decode(DayDiary.self, from: data)
    let now = try XCTUnwrap(ViewerTime.parse("2026-01-15T13:00:00+09:00"))
    let snapshot = WidgetSnapshot(diary: diary, now: now, calendar: calendar) { _ in
      XCTFail("Rejected diary must not export icons")
      return nil
    }
    XCTAssertEqual(snapshot, WidgetSnapshot(day: "2026-01-15"))
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
    try Data(#"{"day":"2026-01-15","segments":[{"start":0,"title":"整理花盆"}]}"#.utf8).write(to: file)
    XCTAssertNil(WidgetSnapshot.readToday(from: file, now: morning, calendar: calendar))
  }

  func testIconPathIsRestrictedToGeneratedPNGFilenames() {
    let directory = WidgetSnapshot.iconDirectory(for: URL(fileURLWithPath: "/tmp/widget/today.json"))
    let hex = String(repeating: "a0", count: 32)
    XCTAssertEqual(WidgetSnapshot.iconURL(named: hex + ".png", in: directory)?.path, "/tmp/widget/icons/\(hex).png")
    for name in ["../\(hex.dropFirst(3)).png", hex + ".jpg", hex.uppercased() + ".png"] {
      XCTAssertNil(WidgetSnapshot.iconURL(named: name, in: directory))
    }
  }
}
