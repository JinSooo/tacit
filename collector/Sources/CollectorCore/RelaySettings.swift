import Foundation

public struct RelaySettings: Decodable, Sendable {
  public enum Mode: String, Decodable, Sendable { case off, custom }

  public struct Device: Decodable, Sendable {
    public let device: String
    public let pending: Int?
  }

  public struct Retiring: Decodable, Sendable {
    public let url: String
    public let retireAt: String
  }

  public let mode: Mode
  public let url: String?
  public let connected: Bool
  public let lastFetchAt: String?
  public let usedBytes: Int?
  public let unprocessable: Int
  public let devices: [Device]
  public let retiring: [Retiring]
}

public enum RelaySettingsText {
  public static let invalidAddress = "请输入有效的 HTTPS 信箱地址，本机可用 HTTP。"

  /// 与后台服务约定一致，只有 localhost 和 127.0.0.1 可以使用 HTTP。
  public static func validatedAddress(_ input: String) -> String? {
    let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let disallowed = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    guard address.rangeOfCharacter(from: disallowed) == nil, !address.contains("\\"),
          let parts = URLComponents(string: address),
          let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          (0...65535).contains(parts.port ?? 443), parts.url != nil,
          scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
    return address
  }

  public static func connection(_ settings: RelaySettings, calendar: Calendar = .current) -> String? {
    guard settings.mode == .custom else { return nil }
    guard settings.connected else { return "连不上信箱，请检查地址和网络。" }
    guard let date = settings.lastFetchAt.flatMap(ViewerTime.parse) else { return "已连接" }
    return "已连接，上次取信 \(monthDay(date, calendar: calendar)) \(ViewerFormat.clock(date, calendar: calendar))"
  }

  public static func pending(_ settings: RelaySettings) -> String? {
    guard settings.mode == .custom else { return nil }
    let count = settings.devices.compactMap(\.pending).filter { $0 > 0 }.reduce(0, +)
    return count > 0 ? "还有 \(count.formatted()) 条等着取" : nil
  }

  public static func retirement(_ settings: RelaySettings, calendar: Calendar = .current) -> String? {
    guard let date = settings.retiring.compactMap({ ViewerTime.parse($0.retireAt) }).max() else { return nil }
    return "旧信箱保留到 \(monthDay(date, calendar: calendar))"
  }

  public static func failure(status: Int?) -> String {
    switch status {
    case 0: return "暂时无法与后台服务通信，请稍后再试。"
    case 400: return "地址无效，或该地址没有 Tacit 信箱。"
    case 403: return "开通码不正确，请检查后再试。"
    case 429: return "信箱请求次数已达今天的上限，请明天再试。"
    case 502: return "连不上信箱，请检查地址和网络。"
    case 503: return "后台服务正忙，请稍后再试。"
    case 507: return "信箱空间已满，请腾出空间后再试。"
    default: return "信箱操作失败，请稍后再试。"
    }
  }

  private static func monthDay(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.month, .day], from: date)
    return "\(parts.month!)月\(parts.day!)日"
  }
}
