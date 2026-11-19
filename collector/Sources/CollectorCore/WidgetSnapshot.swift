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

/// This is the entire file shared with the extension. Keep authenticated API types in the host.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
  public struct Segment: Codable, Equatable, Sendable {
    public let start: Date
    public let title: String

    public init(start: Date, title: String) {
      self.start = start
      self.title = title
    }
  }

  public let day: String
  public let summary: String?
  public let segments: [Segment]

  public init(day: String, summary: String? = nil, segments: [Segment] = []) {
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
