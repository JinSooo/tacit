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

  func testSnapshotIncludesTodaysPublicDraftsWithOrWithoutReview() throws {
    let now = try XCTUnwrap(ViewerTime.parse("2026-01-15T13:00:00+09:00"))
    let draft: [String: Any] = [
      "id": "draft-1", "title": "苗圃群", "excerpt": "我给育苗盘换了位置。",
      "t_start": "2026-01-15T11:00:00+09:00", "t_end": "2026-01-15T11:03:00+09:00",
      "active_seconds": 180, "sources": ["mac.wechat"], "apps": [["source": "mac.wechat"]],
      "record_ids": ["public-1"],
    ]
    let earlier = [
      "id": "review-1", "title": "测量种植槽", "description": "标好育苗区。",
      "t_start": "2026-01-15T08:00:00+09:00", "t_end": "2026-01-15T08:30:00+09:00",
      "active_seconds": 1800, "sources": ["manual.note"], "evidence": [], "record_ids": ["public-2"],
    ] as [String: Any]
    let detail: [String: Any] = ["summary": "标好了育苗区。", "items": [earlier]]
    let response: [String: Any] = ["date": "2026-01-15", "drafts": [draft]]
    let draftOnly = try HubJSON.decoder().decode(DayDiary.self, from: JSONSerialization.data(withJSONObject: response))
    let snapshot = WidgetSnapshot(diary: draftOnly, now: now, calendar: calendar)
    XCTAssertNil(snapshot.summary)
    XCTAssertEqual(snapshot.segments.map(\.title), ["苗圃群"])
    XCTAssertEqual(snapshot.segments.first?.description, "我给育苗盘换了位置。")

    let mixed = response.merging(["detail": detail]) { _, new in new }
    let diary = try HubJSON.decoder().decode(DayDiary.self, from: JSONSerialization.data(withJSONObject: mixed))
    let withReview = WidgetSnapshot(diary: diary, now: now, calendar: calendar)
    XCTAssertEqual(withReview.summary, "标好了育苗区。")
    XCTAssertEqual(withReview.segments.map(\.title), ["苗圃群", "测量种植槽"])
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(withReview), as: UTF8.self).contains("public-1"))
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

  func testUpgradeStopsOnlyWidgetProcessesStartedBeforeTheNewBinary() {
    // 回归：升级后旧扩展进程继续运行，系统重绘一直报版本不符，小组件停在升级前的画面。
    let installed = Date(timeIntervalSince1970: 1_000)
    let executable = "/Applications/Tacit.app/Contents/PlugIns/TacitWidget.appex/Contents/MacOS/TacitWidget"
    let processes = [
      StaleExtension.Process(pid: 10, path: executable, started: installed.addingTimeInterval(-3600)),
      StaleExtension.Process(pid: 11, path: executable, started: installed.addingTimeInterval(5)),
      StaleExtension.Process(pid: 12, path: "/Applications/Other.app/Contents/MacOS/TacitWidget",
                             started: installed.addingTimeInterval(-3600)),
    ]
    XCTAssertEqual(StaleExtension.pids(among: processes, executable: executable, installedAt: installed), [10])
  }
}
