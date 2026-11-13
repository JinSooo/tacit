import Foundation

/// EventKit 的值快照；筛选与记录生成不依赖系统权限。
public struct CalendarEventSnapshot {
  public var externalIdentifier: String
  public var start: Date
  public var end: Date
  public var title: String
  public var calendar: String
  public var organizer: String?
  public var location: String?
  public var attendees: [String]
  public var notes: String?
  public var allDay: Bool
  public var declined: Bool
  public var canceled: Bool

  public init(externalIdentifier: String, start: Date, end: Date, title: String, calendar: String,
              organizer: String? = nil, location: String? = nil, attendees: [String] = [], notes: String? = nil,
              allDay: Bool = false, declined: Bool = false, canceled: Bool = false) {
    self.externalIdentifier = externalIdentifier; self.start = start; self.end = end
    self.title = title; self.calendar = calendar; self.organizer = organizer
    self.location = location; self.attendees = attendees; self.notes = notes
    self.allDay = allDay; self.declined = declined; self.canceled = canceled
  }

  public var sourceRef: String { externalIdentifier + "|" + LocalTime.iso(start, timeZone: TimeZone(secondsFromGMT: 0)!) }

  public func record(now: Date, device: String) -> Record? {
    guard !allDay, !declined, !canceled, end <= now, end >= now.addingTimeInterval(-36 * 3600),
          end > start, !externalIdentifier.isEmpty, sourceRef.count <= 512 else { return nil }
    let names = attendees.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: [String] = []
    if let location, !location.isEmpty { body.append("地点：" + location) }
    if !names.isEmpty { body.append("参会人：" + names.joined(separator: "、")) }
    if let notes, !notes.isEmpty { body.append("备注：" + Text.capturePrefix(notes, limit: 2000, suffix: "")) }
    var extra: [String: ContextValue] = ["calendar": .string(calendar)]
    if let organizer { extra["organizer"] = .string(organizer) }
    return Record(device: device, source: "mac.calendar", kind: "span", start: start, end: end,
                  context: RecordContext(app: "com.apple.iCal", extra: extra), title: "日程 · " + title,
                  body: Text.capturePrefix(body.joined(separator: "\n"), limit: 199990), capture: Capture(method: "api"),
                  sourceRef: sourceRef, people: names)
  }
}

public struct CalendarRecordBuffer {
  private var seen: Set<String> = []
  public init() {}
  public mutating func records(_ events: [CalendarEventSnapshot], now: Date, device: String) -> [Record] {
    events.compactMap { event in
      guard let record = event.record(now: now, device: device), seen.insert(event.sourceRef).inserted else { return nil }
      return record
    }
  }
}

/// 只认可有正时长交集的日程；边界相接不算开会，不要求日程已经结束。
public enum CalendarMeetingPolicy {
  public static func meetingApps(_ apps: [String], events: [CalendarEventSnapshot],
                                 start: Date, end: Date, authorized: Bool) -> [String] {
    var result = Set(apps)
    if authorized, end > start, events.contains(where: {
      !$0.allDay && !$0.declined && !$0.canceled && $0.end > $0.start && $0.start < end && $0.end > start
    }) {
      result.insert("com.apple.iCal")
    }
    return result.sorted()
  }
}
