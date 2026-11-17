import Foundation
import Testing
@testable import CollectorCore

private func segment(_ id: String, project: String?) throws -> DayDiary.Item {
  let value: [String: Any] = ["id": id, "title": "修复示例", "description": "更新了示例页面",
    "t_start": "2026-11-17T09:00:00+09:00", "t_end": "2026-11-17T09:30:00+09:00",
    "active_seconds": 1800, "sources": [], "evidence": [], "project_id": project as Any? ?? NSNull()]
  return try HubJSON.decoder().decode(DayDiary.Item.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func labelsOnlyDisambiguateMultipleProjectsWithinOneDay() throws {
  let a = try segment("a", project: "atlas"), b = try segment("b", project: "harbor")
  let unassigned = try segment("c", project: nil), blank = try segment("d", project: "")
  #expect(!TimelineProjectLabels.showsNames(in: []))
  #expect(!TimelineProjectLabels.showsNames(in: [unassigned, blank]))
  #expect(!TimelineProjectLabels.showsNames(in: [a, a, unassigned]))
  #expect(TimelineProjectLabels.showsNames(in: [a, b, unassigned]))
  #expect(!TimelineProjectLabels.showsNames(in: [a, b], projectFiltered: true))
}

@Test func dedicatedSourcesResolveInstalledAppIdentityWithoutOverridingExplicitApps() {
  #expect(SourceApplication.bundle(app: nil, source: "codex.session") == "com.openai.codex")
  #expect(SourceApplication.bundle(app: "Claude", source: "claude_code.session") == "com.anthropic.claudefordesktop")
  #expect(SourceApplication.bundle(app: nil, source: "mac.wechat") == "com.tencent.xinWeChat")
  #expect(SourceApplication.bundle(app: "腾讯会议", source: "mac.audio") == "com.tencent.meeting")
  #expect(SourceApplication.bundle(app: "org.example.unknown", source: "codex.session") == "org.example.unknown")
  #expect(SourceApplication.bundle(app: nil, source: "mac.audio") == nil)
}
