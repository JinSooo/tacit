import Foundation
import CollectorCore

/// 界面上的数字和时长写法（docs/ui.md 第 5 节）：带单位，千位加逗号，≥ 1 小时写"x 小时 y 分"，不足 1 分钟写"不到 1 分钟"。
enum Fmt {
  static func duration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return L10n.text(zh: "不到 1 分钟", en: "Less than a minute") }
    return ViewerFormat.duration(seconds)
  }

  /// 说话时长：声音样本常常只有几十秒，不足 1 分钟写到秒，例如"38 秒"。
  static func speech(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds.rounded()))
    return s < 60 ? ViewerFormat.duration(TimeInterval(max(1, s))) : duration(seconds)
  }

  static func count(_ n: Int) -> String { L10n.number(n) }

  static func updated(_ date: Date) -> String { ViewerFormat.updated(date) }

  static func date(_ d: Date) -> String { ViewerFormat.date(d) }

  /// "11 月 24 日 09:00"；不是今年的带上年份。
  static func dateTime(_ d: Date) -> String { "\(date(d)) \(ViewerFormat.clock(d))" }

  static func range(_ a: Date, _ b: Date?) -> String {
    guard let b, ViewerFormat.clock(b) != ViewerFormat.clock(a) else { return ViewerFormat.clock(a) }
    return "\(ViewerFormat.clock(a))–\(ViewerFormat.clock(b))"
  }

  /// 试听片段来自哪段对话："11 月 9 日 10:23"。取不到时间时不显示。
  static func stamp(_ iso: String?) -> String? {
    guard let iso, let d = ViewerTime.parse(iso) else { return nil }
    return "\(date(d)) \(ViewerFormat.clock(d))"
  }
}

/// 试听片段下面的说明。一段模糊的录音很难凭音色认出是谁，所以带上时间和他当时说的话。
enum SampleNote {
  static func line(at: String?, said: String?) -> String { CollectorCore.SampleNote.line(stamp: Fmt.stamp(at), said: said) }
}

/// 一场对话在列表里的标题：有总结时用总结里的标题，否则只写L10n.text(zh: "对话", en: "Conversation")/"手机录音"（时长在行尾）。不再列"说话人 OK"这类编号。
enum ConversationText {
  static func title(_ c: ConversationRef, source: String = "mac.audio") -> String {
    let label = SourceInfo.name(source == "android.audio" ? source : "mac.audio")
    guard let t = c.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return label }
    return L10n.text(zh: "\(label)：\(t)", en: "\(label): \(t)")
  }
}

/// 记录标题的显示写法。采集端存的标题是"应用 · 窗口""复制 · 文字""对话 · 时间 · 人"，
/// 界面上不用中间点拼接：旁边已经有应用图标时去掉应用名，其余前缀改成冒号。
@MainActor enum RecordText {
  static func title(_ r: HistoryRecord, appShown: Bool = true) -> String {
    title(r.title, source: r.source, app: r.contextText("app"), appShown: appShown)
  }

  static func title(_ raw: String, source: String, app: String? = nil, appShown: Bool = false) -> String {
    RecordTitles.display(raw, source: source, appShown: appShown) ?? SourceInfo.name(source)
  }
}

extension Lane {
  /// 时间轴泳道名（CollectorCore 里的 Lane.title 仍写 "Agent"，界面统一叫L10n.text(zh: "AI 工具", en: "AI tools")）。
  var name: String {
    switch self {
    case .screen: return L10n.text(zh: "屏幕", en: "Screen")
    case .browser: return L10n.text(zh: "浏览器", en: "Browser")
    case .agent: return L10n.text(zh: "AI 工具", en: "AI tools")
    case .terminal: return L10n.text(zh: "终端", en: "Terminal")
    case .voice: return L10n.text(zh: "对话", en: "Conversation")
    case .other: return L10n.text(zh: "其他", en: "Other")
    }
  }
}
