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

  /// 没装这个应用时，借用同一家已装应用的图标（Codex 没有独立应用时用 ChatGPT）。
  public static let substitutes = ["com.openai.codex": "com.openai.chat"]

  private static let aliases = [
    "claude": "com.anthropic.claudefordesktop", "claude code": "com.anthropic.claudefordesktop", "claude-code": "com.anthropic.claudefordesktop",
    "codex": "com.openai.codex", "wechat": "com.tencent.xinWeChat", "微信": "com.tencent.xinWeChat",
    "zoom": "us.zoom.xos", "腾讯会议": "com.tencent.meeting", "voov meeting": "com.tencent.meeting",
    "microsoft teams": "com.microsoft.teams2", "钉钉": "com.alibaba.DingTalkMac",
    "slack": "com.tinyspeck.slackmacgap", "discord": "com.hnc.Discord",
  ]
}

/// A generated result can have a wall-clock range without any user presence.
public enum TimelinePresence {
  public static func hasDuration(activeSeconds: Double, start: Date, end: Date) -> Bool {
    activeSeconds > 0 && end > start
  }
  public static func repeatsTitle(recordCount: Int, recordTitle: String, segmentTitle: String) -> Bool {
    recordCount == 1 && recordTitle.trimmingCharacters(in: .whitespacesAndNewlines) == segmentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum TimelineSetup {
  /// Unknown backend state must not be mistaken for unfinished setup.
  public static func shouldShow(permissionsReady: Bool, modelReady: Bool?, agentReady: Bool?) -> Bool {
    guard let modelReady, let agentReady else { return false }
    return !permissionsReady || !modelReady || !agentReady
  }
}

public enum CaptureFooterStatus {
  public enum State { case recording, paused(Date), noPermission }
  public static func title(state: State, enabledSources: Int) -> String {
    switch state {
    case .paused(let until): return L10n.text(zh: "已暂停到 \(ViewerFormat.clock(until))", en: "Paused until \(ViewerFormat.clock(until))")
    case .recording: return enabledSources == 0 ? L10n.text(zh: "未在记录", en: "Not recording") : L10n.text(zh: "正在记录", en: "Recording")
    case .noPermission: return enabledSources == 0 ? L10n.text(zh: "未在记录", en: "Not recording") : L10n.text(zh: "需要辅助功能权限", en: "Accessibility permission required")
    }
  }
}
