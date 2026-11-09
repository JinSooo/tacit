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
    if let notes, !notes.isEmpty { body.append("备注：" + String(notes.prefix(2000))) }
    var extra: [String: ContextValue] = ["calendar": .string(calendar)]
    if let organizer { extra["organizer"] = .string(organizer) }
    return Record(device: device, source: "mac.calendar", kind: "span", start: start, end: end,
                  context: RecordContext(app: "com.apple.iCal", extra: extra), title: "日程 · " + title,
                  body: String(body.joined(separator: "\n").prefix(200000)), capture: Capture(method: "api"),
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
