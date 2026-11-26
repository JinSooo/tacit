import Foundation

public enum L10n {
  public static func text(zh: @autoclosure () -> String, en: @autoclosure () -> String, lang: AppLanguage = .current) -> String {
    lang == .zh ? zh() : en()
  }

  public static func number(_ n: Int) -> String {
    n.formatted(.number.locale(Locale(identifier: "en_US")))
  }

  /// Use `%@` for the grouped count in each template.
  public static func count(_ n: Int, one: String, other: String, zh: String, lang: AppLanguage = .current) -> String {
    text(zh: zh, en: n == 1 ? one : other, lang: lang).replacingOccurrences(of: "%@", with: number(n))
  }

  public static func speaker(_ label: String, lang: AppLanguage = .current) -> String {
    guard lang == .en else { return label }
    switch label {
    case "我": return "Me"
    case "对方": return "Speaker"
    case "其他人": return "Others"
    default:
      guard label.hasPrefix("对方 "), let n = Int(label.dropFirst(3)), n > 0 else { return label }
      return "Speaker \(n)"
    }
  }

  public static func englishDuration(minutes: Int) -> String {
    if minutes < 60 { return "\(number(minutes)) min" }
    return "\(number(minutes / 60)) hr \(minutes % 60) min"
  }

  public static func clock(_ date: Date, lang: AppLanguage = .current, calendar: Calendar = .current,
                           region: String? = Locale.current.region?.identifier) -> String {
    if lang == .zh {
      let c = calendar.dateComponents([.hour, .minute], from: date)
      return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    let formatter = DateFormatter()
    formatter.locale = lang.locale(region: region)
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return formatter.string(from: date)
  }

  public static func dayHeader(_ date: Date, lang: AppLanguage = .current) -> String {
    if lang == .zh {
      return date.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }
    let formatter = DateFormatter()
    formatter.locale = lang.locale()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter.string(from: date)
  }
}
