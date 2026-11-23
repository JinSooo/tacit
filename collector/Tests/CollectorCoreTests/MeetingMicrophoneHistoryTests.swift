import Foundation
import Testing
@testable import CollectorCore

@Test func idleMeetingAppsDoNotTriggerException() {
  var history = MeetingMicrophoneHistory()
  // 合成场景：微信、飞书常开，但当前只有非会议软件在使用麦克风。
  history.observe(inputBundles: ["dev.synthetic.recorder", "dev.record-anything.collector"], at: t0)
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(3)).isEmpty)
  history.observe(inputBundles: ["com.tencent.xinWeChat", "dev.synthetic.recorder"], at: t0.addingTimeInterval(3))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(3)) == ["com.tencent.xinWeChat"])
  // 查询失败或停止用麦克风后，空采样不能沿用上一次的使用状态。
  history.observe(inputBundles: [], at: t0.addingTimeInterval(6))
  #expect(history.apps(since: t0.addingTimeInterval(6), through: t0.addingTimeInterval(9)).isEmpty)
}

@Test func meetingMicrophoneWhitelistRetainsAllSupportedBundles() {
  for bundle in ["com.tencent.meeting", "com.tencent.wemeet", "com.ss.desktop.lark", "com.electron.lark",
                 "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
                 "com.tencent.xinWeChat", "com.tencent.xinwechat",
                 "com.alibaba.DingTalkMac", "com.tencent.qq", "ru.keepcoder.Telegram",
                 "com.tencent.WeWorkMac", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "Cisco-Systems.Spark"] {
    var history = MeetingMicrophoneHistory()
    history.observe(inputBundles: [bundle, "dev.synthetic.recorder"], at: t0)
    #expect(history.apps(since: t0, through: t0) == [bundle])
  }
}

@Test func meetingMicrophoneWindowIncludesToleranceAndEndButExcludesOutside() {
  var history = MeetingMicrophoneHistory()
  history.observe(inputBundles: ["com.tencent.meeting"], at: t0.addingTimeInterval(-1.01))
  history.observe(inputBundles: ["com.tencent.xinWeChat"], at: t0.addingTimeInterval(-1))
  history.observe(inputBundles: ["us.zoom.xos", "com.tencent.xinWeChat"], at: t0.addingTimeInterval(3))
  history.observe(inputBundles: ["com.microsoft.teams2"], at: t0.addingTimeInterval(3.01))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(3)) == ["com.tencent.xinWeChat", "us.zoom.xos"])
}

@Test func meetingMicrophoneHistoryExpiresOnlyAfterNinetySeconds() {
  var history = MeetingMicrophoneHistory()
  history.observe(inputBundles: ["com.tencent.meeting"], at: t0)
  history.observe(inputBundles: ["us.zoom.xos"], at: t0.addingTimeInterval(90))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(90)) == ["com.tencent.meeting", "us.zoom.xos"])
  history.observe(inputBundles: [], at: t0.addingTimeInterval(90.01))
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(91)) == ["us.zoom.xos"])
}

@Test func browsersAndMusicAppsAreNotMeetings() {
  var history = MeetingMicrophoneHistory()
  history.observe(inputBundles: ["com.google.Chrome", "app.zen-browser.zen", "com.tencent.QQMusicMac"], at: t0)
  #expect(history.apps(since: t0, through: t0).isEmpty)
}

@Test func disabledRecordingDoesNotReadMicrophoneProcesses() {
  var history = MeetingMicrophoneHistory(), reads = 0
  let read = { reads += 1; return Set(["com.tencent.meeting"]) }
  history.sample(enabled: false, speaking: false, at: t0, read: read)
  history.sample(enabled: false, speaking: true, at: t0.addingTimeInterval(60), read: read)
  #expect(reads == 0)
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(60)).isEmpty)

  history.sample(enabled: true, speaking: false, at: t0.addingTimeInterval(61), read: read)
  #expect(reads == 1)
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(61)) == ["com.tencent.meeting"])
}

@Test func disabledRecordingDropsMeetingSamplesAndResumeProbesImmediately() {
  var history = MeetingMicrophoneHistory(), reads = 0
  history.sample(enabled: true, speaking: false, at: t0) { reads += 1; return ["com.tencent.meeting"] }
  history.sample(enabled: false, speaking: false, at: t0.addingTimeInterval(1)) { reads += 1; return [] }
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(2)).isEmpty)
  history.sample(enabled: true, speaking: false, at: t0.addingTimeInterval(2)) { reads += 1; return [] }
  #expect(reads == 2)
  #expect(history.apps(since: t0, through: t0.addingTimeInterval(2)).isEmpty)
}

@Test func meetingProbeKeepsExistingSpeakingAndIdleCadence() {
  var history = MeetingMicrophoneHistory(), reads = 0
  let read = { reads += 1; return Set<String>() }
  history.sample(enabled: true, speaking: false, at: t0, read: read)
  history.sample(enabled: true, speaking: false, at: t0.addingTimeInterval(9.99), read: read)
  #expect(reads == 1)
  history.sample(enabled: true, speaking: false, at: t0.addingTimeInterval(10), read: read)
  #expect(reads == 2)
  history.sample(enabled: true, speaking: true, at: t0.addingTimeInterval(11), read: read)
  history.sample(enabled: true, speaking: true, at: t0.addingTimeInterval(12), read: read)
  #expect(reads == 4)
}

@Test func idleWithoutActiveConversationSkipsMeetingProbeAndSupportsOnDemandCheck() {
  var history = MeetingMicrophoneHistory(), reads = 0
  let read = { reads += 1; return Set(["us.zoom.xos"]) }
  // 无活跃人声且无进行中对话时，不触发 CoreAudio 进程枚举。
  history.sample(enabled: true, active: false, speaking: false, at: t0, read: read)
  history.sample(enabled: true, active: false, speaking: false, at: t0.addingTimeInterval(30), read: read)
  #expect(reads == 0)
  #expect(!history.hasSample(since: t0, through: t0.addingTimeInterval(30)))

  // 说话开始后立即采样；进入对话后维持 10 秒轮询。
  history.sample(enabled: true, active: false, speaking: true, at: t0.addingTimeInterval(31), read: read)
  #expect(reads == 1)
  #expect(history.hasSample(since: t0.addingTimeInterval(31), through: t0.addingTimeInterval(32)))
  #expect(history.apps(since: t0.addingTimeInterval(31), through: t0.addingTimeInterval(32)) == ["us.zoom.xos"])

  history.sample(enabled: true, active: true, speaking: false, at: t0.addingTimeInterval(40), read: read)
  #expect(reads == 1)
  history.sample(enabled: true, active: true, speaking: false, at: t0.addingTimeInterval(41), read: read)
  #expect(reads == 2)

  // 关闭录音时仍立即清空样本。
  history.sample(enabled: false, active: true, speaking: true, at: t0.addingTimeInterval(42), read: read)
  #expect(reads == 2)
  #expect(history.apps(since: t0.addingTimeInterval(31), through: t0.addingTimeInterval(42)).isEmpty)
}
