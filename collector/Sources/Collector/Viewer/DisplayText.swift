import Foundation
import CollectorCore

/// 界面上的数字和时长写法（docs/ui.md 第 5 节）：带单位，千位加逗号，≥ 1 小时写"x 小时 y 分"，不足 1 分钟写"不到 1 分钟"。
enum Fmt {
  static func duration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "不到 1 分钟" }
    let m = s / 60
    if m < 60 { return "\(m) 分钟" }
    return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分"
  }

  /// 说话时长：声音样本常常只有几十秒，不足 1 分钟写到秒，例如"38 秒"。
  static func speech(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds.rounded()))
    return s < 60 ? "\(max(1, s)) 秒" : duration(seconds)
  }

  private static let grouped: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")
    f.groupingSeparator = ","
    f.usesGroupingSeparator = true
    return f
  }()
  static func count(_ n: Int) -> String { grouped.string(from: NSNumber(value: n)) ?? String(n) }

  /// "6 分钟前更新"、"刚刚更新"。
  static func updated(_ date: Date) -> String {
    let r = ViewerFormat.relative(date)
    return r == "刚刚" ? "刚刚更新" : "\(r)更新"
  }

  /// "11 月 10 日"；不是今年的带上年份。
  static func date(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    let year = c.year != Calendar.current.component(.year, from: Date()) ? "\(c.year!) 年 " : ""
    return "\(year)\(c.month!) 月 \(c.day!) 日"
  }

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

/// 一场对话在列表里的标题：有总结时用总结里的标题，否则只写"对话"（时长在行尾）。不再列"说话人 OK"这类编号。
enum ConversationText {
  static func title(_ c: ConversationRef) -> String {
    guard let t = c.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return "对话" }
    return "对话：\(t)"
  }
}

/// 记录标题的显示写法。采集端存的标题是"应用 · 窗口""复制 · 文字""对话 · 时间 · 人"，
/// 界面上不用中间点拼接：旁边已经有应用图标时去掉应用名，其余前缀改成冒号。
@MainActor enum RecordText {
  static func title(_ r: HistoryRecord, appShown: Bool = true) -> String {
    title(r.title, source: r.source, app: r.contextText("app"), appShown: appShown)
  }

  static func title(_ raw: String, source: String, app: String? = nil, appShown: Bool = false) -> String {
    let t = raw.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return SourceInfo.name(source) }
    let parts = t.components(separatedBy: " · ")
    guard parts.count > 1 else { return t }
    let head = parts[0], rest = parts.dropFirst().joined(separator: " · ").trimmingCharacters(in: .whitespaces)
    switch source {
    case "mac.screen", "mac.app":
      if rest.isEmpty || rest == head || rest == "无标题" || rest == "（无标题）" { return head }
      return appShown ? rest : "\(head)：\(rest)"
    case "mac.audio":
      // 对话 · 10:00–10:30 · 说话人 OK、我：时间在旁边已经有了；人名是转写当时的编号，对人没有意义（用户报告），只写"对话"。
      // 有总结时，列表和详情用总结里的标题（ConversationText）。
      return "对话"
    case "mac.wechat":
      return parts.count >= 3 ? "\(parts[1])：\(parts.dropFirst(2).joined(separator: " "))" : "微信：\(rest)"
    default:
      return "\(head)：\(rest)"
    }
  }
}

extension Lane {
  /// 时间轴泳道名（CollectorCore 里的 Lane.title 仍写 "Agent"，界面统一叫"AI 工具"）。
  var name: String {
    switch self {
    case .screen: return "屏幕"
    case .browser: return "浏览器"
    case .agent: return "AI 工具"
    case .terminal: return "终端"
    case .voice: return "对话"
    case .other: return "其他"
    }
  }
}
