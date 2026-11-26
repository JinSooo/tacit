import Foundation

public extension L10n {
  enum Menu {
    public static var pause: String { text(zh: "暂停", en: "Pause") }
    public static var pauseHour: String { text(zh: "暂停 1 小时", en: "Pause for 1 hour") }
    public static var pauseTomorrow: String { text(zh: "暂停到明天", en: "Pause until tomorrow") }
    public static var resume: String { text(zh: "继续记录", en: "Resume recording") }
    public static var open: String { text(zh: "打开 Tacit", en: "Open Tacit") }
    public static var settings: String { text(zh: "设置", en: "Settings") }
    public static var microphone: String { text(zh: "麦克风", en: "Microphone") }
    public static var installationIncomplete: String { text(zh: "安装不完整，请重新安装 Tacit", en: "Installation incomplete. Reinstall Tacit") }
    public static func queued(_ n: Int) -> String {
      count(n, one: "%@ record waiting to be saved", other: "%@ records waiting to be saved", zh: "%@ 条记录等待保存")
    }
  }
}
