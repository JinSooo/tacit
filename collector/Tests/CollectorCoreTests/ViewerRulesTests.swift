import Foundation
import Testing
@testable import CollectorCore

private func read(_ id: String, tool: String = "claude-code", kind: String = "context", args: String = #"{"cwd":"/tmp/repo","event":"startup"}"#,
                  ok: Bool = true) -> AuditRead {
  let json = #"{"id":"\#(id)","at":"2026-11-10T09:00:00Z","tool":"\#(tool)","kind":"\#(kind)","args":\#(args),"result_ids":[],"bytes":10,"ok":\#(ok ? 1 : 0)}"#
  return try! HubJSON.decoder().decode(AuditRead.self, from: Data(json.utf8))
}

// 用户报告：读取记录页十几行一模一样的"会话开始时注入 ~/…"。
@Test func identicalAdjacentReadsCollapseIntoOneRow() {
  let groups = AuditGrouping.group([read("a"), read("b"), read("c"), read("d", kind: "now", args: "{}"), read("e")])
  #expect(groups.map { $0.reads.map(\.id) } == [["a", "b", "c"], ["d"], ["e"]])
  #expect(groups[0].latest.id == "a")
}

@Test func readsDifferingInToolDirectoryTargetOrResultStaySeparate() {
  let groups = AuditGrouping.group([
    read("a"), read("b", tool: "codex"), read("c", args: #"{"cwd":"/tmp/other","event":"startup"}"#),
    read("d", args: #"{"cwd":"/tmp/other","event":"compact"}"#), read("e", args: #"{"cwd":"/tmp/other","event":"compact"}"#, ok: false),
    read("f", kind: "get", args: #"{"id":"t1","level":"brief"}"#), read("g", kind: "get", args: #"{"id":"t2","level":"brief"}"#),
  ])
  #expect(groups.count == 7)
}

@Test func threadDoneDoesNotInferArchiveDateFromCalendarDays() {
  let created = "2026-11-03T12:00:00Z"
  #expect(PendingArchive.notice(createdAt: created) == "继续使用后会自动归档")
  #expect(PendingArchive.notice(createdAt: nil) == nil)
}

// 用户报告：数据源状态"成功 · 新增 0 · 0s"里的 0s 没有意义。
@Test func pluginOutcomeOmitsSubSecondDurationAndUsesChineseUnits() {
  #expect(PluginImport.outcomeText(ok: true, exitStatus: 0, accepted: 0, elapsed: 0.4) == "没有新记录")
  #expect(PluginImport.outcomeText(ok: true, exitStatus: 0, accepted: 3, elapsed: 2.7) == "新增 3 条，用时 2 秒")
  #expect(PluginImport.outcomeText(ok: false, exitStatus: 1, accepted: nil, elapsed: 125) == "失败（退出码 1），用时 2 分 5 秒")
  #expect(PluginImport.outcomeText(ok: true, exitStatus: 0, accepted: nil, elapsed: 180) == "完成，用时 3 分钟")
}

private let builtin = MicrophoneDevice(uid: "builtin-uid", name: "MacBook Pro Microphone", isBuiltIn: true)

@Test func microphoneChoicesMatchMenuOrder() {
  let choices = MicrophoneChoices.list(devices: [builtin], setting: "builtin")
  #expect(choices.map(\.title) == ["自带麦克风（默认）", "跟随系统默认", "MacBook Pro Microphone"])
  #expect(choices.map(\.value) == ["builtin", "system", "builtin-uid"])
  #expect(choices.allSatisfy { $0.selectable })

  let missing = MicrophoneChoices.list(devices: [builtin], setting: "gone")
  #expect(missing.last == MicrophoneChoice(title: "所选设备已断开", value: "gone", selectable: false, group: .notice))
  let unreadable = MicrophoneChoices.list(devices: nil, setting: "builtin")
  #expect(unreadable.map(\.title) == ["自带麦克风（默认）", "跟随系统默认", "无法读取输入设备"])
}

// 用户报告：菜单栏里麦克风子菜单之外还有一行"麦克风：MacBook Pro Microphone"。
@Test func microphoneDeviceLineIsDroppedButFallbackNoticeKept() {
  #expect(MicrophoneChoices.statusLines(["麦克风：MacBook Pro Microphone", "麦克风可能没有权限"]) == ["麦克风可能没有权限"])
  #expect(MicrophoneChoices.statusLines(["麦克风：MacBook Pro Microphone · 已断开，暂用自带麦克风"]) == ["麦克风已断开，暂用自带麦克风"])
  #expect(MicrophoneChoices.statusLines(["麦克风未录音"]) == ["麦克风未录音"])
}

@Test func speakerMenuDropsDuplicateNamesAndNoise() {
  func s(_ id: String, _ name: String?, confirmed: Bool, conversations: Int, seconds: Double, label: String = "说话人 A") -> Speaker {
    Speaker(id: id, label: label, name: name, isMe: FlexBool(false), confirmed: FlexBool(confirmed), conversations: conversations, seconds: seconds)
  }
  let speakers = [
    s("a", "刘朝刚", confirmed: true, conversations: 20, seconds: 889),
    s("b", "刘朝刚", confirmed: true, conversations: 4, seconds: 95),
    s("c", "我", confirmed: true, conversations: 11, seconds: 65, label: "说话人 W"),
    s("d", nil, confirmed: false, conversations: 1, seconds: 2),
    s("e", nil, confirmed: false, conversations: 9, seconds: 155),
    s("f", nil, confirmed: false, conversations: 1, seconds: 120),
    s("g", "金洋", confirmed: true, conversations: 11, seconds: 82),
  ]
  // 同名只留最活跃的一条；排除当前这条。
  // 排序按对话数、再按时长；排除最活跃的那条刘朝刚后，还剩另一条同名的刘朝刚可选。
  #expect(SpeakerMenu.known(speakers, excluding: nil).map(\.name) == ["刘朝刚", "金洋", "我"])
  #expect(SpeakerMenu.known(speakers, excluding: "a").map(\.name) == ["金洋", "我", "刘朝刚"])
  // 只出现一次、两三秒的识别误差不列；只出现一次但说了两分钟的仍要列。
  #expect(SpeakerMenu.unknown(speakers, excluding: nil).map(\.id) == ["e", "f"])
  // 填的名字已经有主时并过去，而不是新建一条同名的。
  #expect(SpeakerMenu.match(" 刘朝刚 ", in: speakers)?.id == "a")
  #expect(SpeakerMenu.match("新的人", in: speakers) == nil)
}
