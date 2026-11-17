import Foundation

/// Count the whole day's distinct project identities, before brush/search filtering.
public enum TimelineProjectLabels {
  public static func showsNames(in items: [DayDiary.Item], projectFiltered: Bool = false) -> Bool {
    !projectFiltered && Set(items.compactMap(\.projectId).filter { !$0.isEmpty }).count > 1
  }
}

/// Dedicated collectors may omit app; resolve only known application identities.
/// An explicit unknown app must not acquire another application's icon.
public enum SourceApplication {
  public static func bundle(app: String?, source: String) -> String? {
    if let app, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return aliases[app.lowercased()] ?? app
    }
    switch source {
    case "claude_code.session": return "com.anthropic.claudefordesktop"
    case "codex.session": return "com.openai.codex"
    case "mac.wechat": return "com.tencent.xinWeChat"
    default: return nil
    }
  }

  private static let aliases = [
    "claude": "com.anthropic.claudefordesktop", "claude code": "com.anthropic.claudefordesktop", "claude-code": "com.anthropic.claudefordesktop",
    "codex": "com.openai.codex", "wechat": "com.tencent.xinWeChat", "微信": "com.tencent.xinWeChat",
    "zoom": "us.zoom.xos", "腾讯会议": "com.tencent.meeting", "voov meeting": "com.tencent.meeting",
    "microsoft teams": "com.microsoft.teams2", "钉钉": "com.alibaba.DingTalkMac",
    "slack": "com.tinyspeck.slackmacgap", "discord": "com.hnc.Discord",
  ]
}
