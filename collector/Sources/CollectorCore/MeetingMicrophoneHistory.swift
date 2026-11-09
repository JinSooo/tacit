import Foundation

/// 会议例外只采用正在使用麦克风的会议软件，保留近期采样供延迟到达的音频段查询。
public struct MeetingMicrophoneHistory {
  public static let meetingBundles: Set<String> = [
    "com.tencent.meeting", "com.tencent.wemeet", "com.ss.desktop.lark", "com.electron.lark",
    "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
    "com.tencent.xinWeChat", "com.tencent.xinwechat"
  ]
  private var samples: [(Date, Set<String>)] = []
  public init() {}

  public mutating func observe(inputBundles: Set<String>, at now: Date) {
    samples.append((now, inputBundles.intersection(Self.meetingBundles)))
    samples.removeAll { now.timeIntervalSince($0.0) > 90 }
  }

  public func apps(since start: Date, through end: Date) -> Set<String> {
    samples.filter { $0.0 >= start.addingTimeInterval(-1) && $0.0 <= end }
      .reduce(into: Set<String>()) { $0.formUnion($1.1) }
  }
}
