import Foundation

public enum TimelineDay {
  public static func key(_ day: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  public static func date(_ key: String, calendar: Calendar = .current) -> Date? {
    let values = key.split(separator: "-").compactMap { Int($0) }
    guard values.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
  }
}

/// The widget reads this projection and its PNG assets. Keep authenticated API types in the host.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
  public struct Segment: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let title: String
    public let description: String
    public let source: String?
    public let icon: String?

    public init(start: Date, end: Date, title: String, description: String, source: String? = nil, icon: String? = nil) {
      self.start = start
      self.end = end
      self.title = title
      self.description = description
      self.source = source
      self.icon = icon
    }
  }

  public let language: AppLanguage?
  public let day: String
  public let summary: String?
  public let segments: [Segment]

  public init(day: String, summary: String? = nil, segments: [Segment] = [], language: AppLanguage? = nil) {
    self.language = language
    self.day = day
    self.summary = summary
    self.segments = segments
  }

  // FileManager resolves home to the extension's container when sandboxed.
  public static var fileURL: URL? {
    guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
    return URL(fileURLWithPath: String(cString: home), isDirectory: true)
      .appendingPathComponent("Library/Application Support/record-anything/widget/today.json")
  }

  /// Legacy snapshots always used Chinese. With no snapshot, use the host's published preference or the system.
  public var resolvedLanguage: AppLanguage { language ?? .zh }

  public static func languageURL(for file: URL) -> URL {
    file.deletingLastPathComponent().appendingPathComponent("language")
  }

  public static func readLanguage(for file: URL) -> AppLanguage? {
    guard let raw = try? String(contentsOf: languageURL(for: file), encoding: .utf8) else { return nil }
    return AppLanguage(rawValue: raw)
  }

  public static func iconDirectory(for file: URL) -> URL {
    file.deletingLastPathComponent().appendingPathComponent("icons", isDirectory: true)
  }

  public static func iconURL(named name: String, in directory: URL) -> URL? {
    guard name.utf8.count == 68, name.hasSuffix(".png"),
          name.utf8.dropLast(4).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
    return directory.appendingPathComponent(name)
  }

  public func activityRange(at now: Date) -> ClosedRange<Date>? {
    guard let start = segments.map(\.start).min(), let end = segments.map(\.end).max() else { return nil }
    return start...max(start, end, now)
  }

  public static func readToday(from file: URL, now: Date = .now, calendar: Calendar = .current) -> Self? {
    guard let data = try? Data(contentsOf: file),
          let snapshot = try? JSONDecoder().decode(Self.self, from: data),
          snapshot.day == TimelineDay.key(now, calendar: calendar) else { return nil }
    return snapshot
  }

  public var timelineURL: URL? { URL(string: "tacit://timeline?date=\(day)") }

  public static func timelineDate(from url: URL, calendar: Calendar = .current) -> Date? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme == "tacit", components.host == "timeline", components.path.isEmpty,
          components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
          let query = components.queryItems, query.count == 1, query[0].name == "date",
          let key = query[0].value, let date = TimelineDay.date(key, calendar: calendar),
          TimelineDay.key(date, calendar: calendar) == key else { return nil }
    return date
  }
}
