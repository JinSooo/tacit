import Foundation

/// 会议例外只采用正在使用麦克风的会议软件，保留近期采样供延迟到达的音频段查询。
public struct MeetingMicrophoneHistory {
  public static let meetingBundles: Set<String> = [
    "com.tencent.meeting", "com.tencent.wemeet", "com.ss.desktop.lark", "com.electron.lark",
    "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
    "com.tencent.xinWeChat", "com.tencent.xinwechat",
    // 2026-11-12 补：钉钉、QQ、Telegram 的 id 在开发机上核对过；企业微信、Slack、Discord、Webex 没装，按官方 id 填。
    // 浏览器不放进来：网页会议和网页里的语音输入分不开。
    "com.alibaba.DingTalkMac", "com.tencent.qq", "ru.keepcoder.Telegram",
    "com.tencent.WeWorkMac", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "Cisco-Systems.Spark"
  ]
  private var samples: [(Date, Set<String>)] = []
  private var lastProbe: Date?
  public init() {}

  /// 对读取闭包限频；关闭录音时不查询系统麦克风使用情况。
  public mutating func sample(enabled: Bool, speaking: Bool, at now: Date, read: () -> Set<String>) {
    guard enabled else {
      samples.removeAll(); lastProbe = nil
      return
    }
    if speaking || lastProbe.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
      lastProbe = now
      observe(inputBundles: read(), at: now)
    }
  }

  /// 没人说话且没有进行中的对话时跳过空闲轮询，避免空闲时段每 10 秒枚举全部系统音频进程；
  /// 说话开始或新对话落盘时按需采样，会议判定窗口不缺样本。
  public mutating func sample(enabled: Bool, active: Bool, speaking: Bool, at now: Date, read: () -> Set<String>) {
    guard enabled else {
      samples.removeAll(); lastProbe = nil
      return
    }
    guard active || speaking else {
      samples.removeAll { now.timeIntervalSince($0.0) > 90 }
      return
    }
    sample(enabled: true, speaking: speaking, at: now, read: read)
  }

  public mutating func observe(inputBundles: Set<String>, at now: Date) {
    samples.append((now, inputBundles.intersection(Self.meetingBundles)))
    samples.removeAll { now.timeIntervalSince($0.0) > 90 }
  }

  public func hasSample(since start: Date, through end: Date) -> Bool {
    samples.contains { $0.0 >= start.addingTimeInterval(-1) && $0.0 <= end }
  }

  public func apps(since start: Date, through end: Date) -> Set<String> {
    samples.filter { $0.0 >= start.addingTimeInterval(-1) && $0.0 <= end }
      .reduce(into: Set<String>()) { $0.formUnion($1.1) }
  }
}
