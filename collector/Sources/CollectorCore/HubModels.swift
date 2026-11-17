import Foundation

/// 客户端从 hub 读到的数据。字段名与 hub 的 JSON 一致（snake_case 由解码器转换）。

public enum JSONValue: Decodable, Hashable, Sendable {
  case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  /// 标量转成一行文字，数组用顿号连接；对象和 null 没有文字。
  public var text: String? {
    switch self {
    case .string(let s): return s.isEmpty ? nil : s
    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    case .bool(let b): return b ? "是" : "否"
    case .array(let a): let parts = a.compactMap(\.text); return parts.isEmpty ? nil : parts.joined(separator: "、")
    case .object, .null: return nil
    }
  }
  public var strings: [String] {
    if case .array(let a) = self { return a.compactMap(\.text) }
    return text.map { [$0] } ?? []
  }
}

/// hub 有的字段返回 0/1，有的返回 true/false。
public struct FlexBool: Decodable, Hashable, Sendable {
  public let value: Bool
  public init(_ value: Bool) { self.value = value }
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let b = try? c.decode(Bool.self) { value = b } else { value = ((try? c.decode(Double.self)) ?? 0) != 0 }
  }
}

public struct HistoryRecord: Decodable, Identifiable, Hashable, Sendable {
  public struct Capture: Decodable, Hashable, Sendable { public let method: String; public let confidence: Double? }
  public let id: String
  public let device: String
  public let source: String
  public let kind: String
  public let tStart: String
  public let tEnd: String?
  public let title: String
  public let body: String?
  public let context: [String: JSONValue]?
  public let capture: Capture?
  public let sensitivity: String?
  public let redactions: Int?
  public let corrects: String?
  public let people: [String]?
  public let start: Date
  public let end: Date?

  enum CodingKeys: String, CodingKey { case id, device, source, kind, tStart, tEnd, title, body, context, capture, sensitivity, redactions, corrects, people }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
    source = try c.decode(String.self, forKey: .source)
    kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "event"
    tStart = try c.decode(String.self, forKey: .tStart)
    tEnd = try c.decodeIfPresent(String.self, forKey: .tEnd)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    body = try c.decodeIfPresent(String.self, forKey: .body)
    context = try c.decodeIfPresent([String: JSONValue].self, forKey: .context)
    capture = try c.decodeIfPresent(Capture.self, forKey: .capture)
    sensitivity = try c.decodeIfPresent(String.self, forKey: .sensitivity)
    redactions = try c.decodeIfPresent(Int.self, forKey: .redactions)
    corrects = try c.decodeIfPresent(String.self, forKey: .corrects)
    people = try c.decodeIfPresent([String].self, forKey: .people)
    guard let s = ViewerTime.parse(tStart) else {
      throw DecodingError.dataCorruptedError(forKey: .tStart, in: c, debugDescription: "t_start 无效")
    }
    start = s
    end = tEnd.flatMap { ViewerTime.parse($0) }
  }

  public func contextText(_ key: String) -> String? { context?[key]?.text }
  public var isSpan: Bool { kind == "span" && end != nil }
  public var seconds: TimeInterval { end.map { max(0, $0.timeIntervalSince(start)) } ?? 0 }
}

public struct RecordDetail: Decodable, Sendable {
  public let record: HistoryRecord
  public let corrections: [HistoryRecord]
  enum CodingKeys: String, CodingKey { case corrections }
  public init(from decoder: Decoder) throws {
    record = try HistoryRecord(from: decoder)
    corrections = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([HistoryRecord].self, forKey: .corrections) ?? []
  }
  /// 显示以最新的修正为准。
  public var current: HistoryRecord {
    corrections.max { ($0.start, $0.id) < ($1.start, $1.id) } ?? record
  }
}

public struct RecordPage: Decodable, Sendable { public let records: [HistoryRecord]; public let nextCursor: String? }

public struct Fact: Decodable, Identifiable, Hashable, Sendable {
  public let id: String
  public let threadId: String?
  public let projectId: String?
  public let kind: String
  public let text: String
  public let reason: String?
  public let evidence: [String]
  public let confidence: Double?
  public let origin: String?
  public let invalidAt: String?
  public let supersededBy: String?
}

public struct Evidence: Decodable, Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let tStart: String
  public let source: String?
  public var start: Date? { ViewerTime.parse(tStart) }
}

public struct HubThread: Decodable, Identifiable, Hashable, Sendable {
  public let id: String
  public let projectId: String?
  public let status: String
  public let title: String
  public let brief: String?
  public let lastMs: Double?
  public let firstMs: Double?
  public let activeMinutes: Int?
  public let sessions: Int?
  public let domain: String?
  public let needsRegen: FlexBool?
  public var last: Date? { lastMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
  public var first: Date? { firstMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
  public var cardSummary: String? {
    let text = brief?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? nil : text
  }
}

public struct Project: Decodable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let brief: String?
  public let confirmed: FlexBool
  public let lastMs: Double?
  public let threadCount: Int?
  public var last: Date? { lastMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// 线程和项目的详细版共用：线程有 progress，项目有 status 和 people。
public struct EntityDetail: Decodable, Sendable {
  public struct Body: Decodable, Sendable {
    public let goal: String?
    public let progress: String?
    public let status: String?
    public let people: [String]?
    public let artifacts: [String: JSONValue]?
  }
  public let id: String
  public let title: String?
  public let name: String?
  public let brief: String?
  public let status: String?
  public let projectId: String?
  public let detail: Body?
  public let facts: [Fact]?
  public let records: [Evidence]?
}

public struct PendingItem: Decodable, Identifiable, Hashable, Sendable {
  public struct Sample: Decodable, Hashable, Sendable { public let id: String; public let mime: String; public let at: String?; public let said: String? }
  public struct ThreadRef: Decodable, Hashable, Sendable { public let id: String; public let title: String; public let brief: String? }
  public struct Keys: Decodable, Hashable, Sendable { public let repos: [String]?; public let hosts: [String]?; public let chats: [String]? }
  public struct Payload: Decodable, Hashable, Sendable {
    public let speakerId: String?
    public let label: String?
    public let conversations: Int?
    public let seconds: Double?
    public let samples: [Sample]?
    public let samplesPending: Bool?
    public let projectId: String?
    public let name: String?
    public let keys: Keys?
    public let threads: [ThreadRef]?
    public let threadId: String?
    public let title: String?
    public let brief: String?
    public let a: String?
    public let b: String?
    public let aName: String?
    public let bName: String?
    public let reason: String?
  }
  public let id: String
  public let kind: String
  public let payload: Payload
  public let createdAt: String?
}

public struct Speaker: Decodable, Identifiable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let name: String?
  public let isMe: FlexBool
  public let confirmed: FlexBool
  public let conversations: Int
  public let seconds: Double
  public var display: String { name?.isEmpty == false ? name! : label }
}

public struct AuditRead: Decodable, Identifiable, Hashable, Sendable {
  public let id: String
  public let at: String
  public let tool: String
  public let kind: String
  public let args: [String: JSONValue]
  public let resultIds: [String]
  public let bytes: Int
  public let ok: FlexBool
  public var date: Date? { ViewerTime.parse(at) }
}

public struct NowState: Decodable, Sendable {
  public let feedback: String?
  public let brief: String?
  public let updatedAt: String?

  public enum Notice: Equatable, Sendable {
    case pending(String), failed(String)
  }

  public var activitySummary: String? {
    let text = brief?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // /v1/now 为没有真实摘要的情况返回占位文字。
    return text.isEmpty || text == Self.pendingBrief || text == Self.emptyBrief ? nil : text
  }

  public var activityNotice: Notice? {
    if let feedback {
      return feedback.hasPrefix("最近一次整理失败") ? .failed(feedback) : .pending(feedback)
    }
    return brief == Self.pendingBrief ? .pending(Self.pendingBrief) : nil
  }

  private static let pendingBrief = "有新活动待整理。"
  private static let emptyBrief = "最近 24 小时没有活跃的线程。"
}

public struct DayDiary: Decodable, Sendable {
  public struct Chapter: Decodable, Hashable, Sendable { public let start: String; public let end: String; public let text: String }
  public struct Reference: Decodable, Identifiable, Hashable, Sendable {
    public let id: String; public let at: String; public let source: String; public let title: String
  }
  public struct Item: Decodable, Identifiable, Hashable, Sendable {
    public struct App: Decodable, Hashable, Sendable {
      public let source: String
      public let app: String?
      public init(source: String, app: String?) { self.source = source; self.app = app }
    }

    public let id: String
    public let title: String
    public let description: String
    public let tStart: String
    public let tEnd: String
    public let activeSeconds: TimeInterval
    public let sources: [String]
    public let evidence: [Reference]
    public let apps: [App]?
    public let recordIds: [String]?
    public let projectId: String?
    public let threadId: String?

    public var start: Date? { ViewerTime.parse(tStart) }
    public var end: Date? { ViewerTime.parse(tEnd) }

    public func intersects(_ range: ClosedRange<Date>) -> Bool {
      guard let start, let end else { return false }
      return start <= range.upperBound && (end > range.lowerBound || (end == start && start == range.lowerBound))
    }
  }
  public struct Body: Decodable, Sendable {
    public let summary: String?
    public let timeline: [Chapter]?
    public let items: [Item]?
    public let omittedRecordIds: [String]?
    public let cutoff: String?
  }
  public let date: String
  public let detail: Body?
  public let needsRegen: FlexBool?
  public let failed: FlexBool?

  public var summary: String? {
    guard detail?.items != nil, let text = detail?.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    return text
  }
}

public enum HubJSON {
  public static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }
}

/// 一场对话（hub 的 /v1/history/segments 里的 conversations）：被静音切开的几条 mac.audio 记录合成一场。
public struct ConversationRef: Decodable, Hashable, Sendable {
  public let id: String
  public let recordIds: [String]
  public let startMs: Double
  public let endMs: Double
  public let app: String?
  /// 总结里的标题；还没总结时为 nil。
  public let title: String?
  public init(id: String, recordIds: [String], startMs: Double, endMs: Double, app: String? = nil, title: String? = nil) {
    self.id = id; self.recordIds = recordIds; self.startMs = startMs; self.endMs = endMs; self.app = app; self.title = title
  }
}

/// 一场对话的整理结果（hub 的 /v1/conversations/:id）：整理过的原文和总结。
public struct ConversationDetail: Decodable, Sendable {
  public struct Turn: Decodable, Hashable, Sendable { public let at: String; public let speaker: String; public let text: String }
  public let id: String
  public let recordIds: [String]
  public let start: String
  public let end: String
  public let app: String?
  /// ready：有总结；waiting：稍后生成；short：太短不总结；private：私密不总结。
  public let state: String
  public let title: String?
  public let summary: String?
  public let points: [String]
  public let turns: [Turn]
  /// 每条记录现在的正文（有修正时用修正）。
  public struct Raw: Decodable, Hashable, Sendable { public let id: String; public let tStart: String; public let body: String }
  public let records: [Raw]?
}

/// History 列表的一段活动（hub 的 /v1/history/segments）：同一线程接得上的记录合成一段，未提炼的按应用临时分组。
public struct HistorySegment: Decodable, Identifiable, Hashable, Sendable {
  public struct App: Decodable, Hashable, Sendable {
    public let app: String?
    public let source: String
    public let records: Int
    public let seconds: Double
    public init(app: String?, source: String, records: Int, seconds: Double) {
      self.app = app; self.source = source; self.records = records; self.seconds = seconds
    }
  }
  public struct ThreadRef: Decodable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let brief: String?
    public let status: String?
    public let domain: String?
    public let projectId: String?
    public let projectName: String?
  }
  public let id: String
  /// "thread"，或 "app"（还没提炼，按应用临时分组）。
  public let kind: String
  public let startMs: Double
  public let endMs: Double
  public let thread: ThreadRef?
  public let apps: [App]
  public let activeSeconds: Double
  /// 从早到晚。
  public let recordIds: [String]
  public let privateCount: Int

  enum CodingKeys: String, CodingKey { case id, kind, startMs, endMs, thread, apps, activeSeconds, recordIds, privateCount = "private" }

  public init(id: String, kind: String, startMs: Double, endMs: Double, thread: ThreadRef?, apps: [App], activeSeconds: Double,
              recordIds: [String], privateCount: Int) {
    self.id = id; self.kind = kind; self.startMs = startMs; self.endMs = endMs; self.thread = thread
    self.apps = apps; self.activeSeconds = activeSeconds; self.recordIds = recordIds; self.privateCount = privateCount
  }

  public var start: Date { Date(timeIntervalSince1970: startMs / 1000) }
  public var end: Date { Date(timeIntervalSince1970: endMs / 1000) }
}
