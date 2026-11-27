import Foundation

public extension L10n {
  static func permission(_ name: String) -> String {
    guard AppLanguage.current == .en else { return name }
    switch name {
    case "辅助功能": return "Accessibility"
    case "录屏": return "Screen Recording"
    case "麦克风": return "Microphone"
    case "完全磁盘访问": return "Full Disk Access"
    default: return name
    }
  }

  static func deliveryIssue(_ message: String) -> String {
    guard AppLanguage.current == .en else { return message }
    if message.hasPrefix("找不到后台服务的访问凭证") { return "Background service credentials are missing" }
    if message.hasPrefix("连不上后台服务") { return "Can't reach the background service" }
    if message.hasPrefix("后台服务拒绝了记录") { return "The background service rejected the records" }
    if message.hasPrefix("后台未确认完整接收") { return "The background service didn't confirm receipt of all records" }
    if message.contains("待发送记录无法安全保存") { return "Pending records couldn't be saved securely" }
    return "Records couldn't be saved"
  }
}

public extension L10n {
  /// The audio coordinator still reports its internal status in Chinese.
  static func audioStatus(_ line: String) -> String {
    guard AppLanguage.current == .en, !line.isEmpty else { return line }
    if line.hasPrefix("今天 ") || line.hasPrefix("待转写 ") {
      return line.components(separatedBy: "，").map { part in
        let words = part.split(separator: " ")
        guard words.count == 3, let n = Int(words[1]) else { return part }
        if words[0] == "今天" {
          return count(n, one: "%@ conversation today", other: "%@ conversations today", zh: part, lang: .en)
        }
        return count(n, one: "%@ conversation awaiting transcription", other: "%@ conversations awaiting transcription",
                     zh: part, lang: .en)
      }.joined(separator: ", ")
    }
    let labels = [
      "麦克风未录音": "Microphone is idle",
      "麦克风可能没有权限": "Check microphone permission",
      "已断开，暂用自带麦克风": "Disconnected. Using the built-in microphone",
      "已断开，找不到自带麦克风": "Disconnected. Built-in microphone unavailable",
      "上次开启录音时崩溃，已暂停录音": "Recording paused after a crash",
      "正在下载语音模型（约 270 MB），完成后自动开始录音。": "Downloading the speech model. Recording will start after the download",
      "系统声音录音需要 macOS 14.2 或更新版本": "System audio recording requires macOS 14.2 or later",
      "转写程序启动失败，请重新安装 Tacit。": "Transcription couldn't start. Reinstall Tacit",
    ]
    if let label = labels[line] { return label }
    if line.hasPrefix("麦克风") {
      let detail = String(line.dropFirst("麦克风".count))
      if !detail.isEmpty, let translated = labels[detail] { return translated }
      return "Check the microphone input and permission"
    }
    return "Check recording in Settings"
  }
}
