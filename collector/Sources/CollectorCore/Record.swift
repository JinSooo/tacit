import Foundation

// 与 schema/record.schema.json 对应的子集；采集端只产出这些字段。

public enum ContextValue: Codable, Equatable {
  case string(String)
  case integer(Int64)

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let n = try? c.decode(Int64.self) { self = .integer(n) }
    else { self = .string(try c.decode(String.self)) }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .integer(let n): try c.encode(n)
    }
  }
}

public struct RecordContext: Codable, Equatable {
  public var app: String?
  public var window: String?
  public var url: String?
  /// 会话名（微信等聊天）。中枢按它把记录切成按会话的片段。
  public var chat: String?
  public var extra: [String: ContextValue]?
  public init(app: String? = nil, window: String? = nil, url: String? = nil, chat: String? = nil,
              extra: [String: ContextValue]? = nil) {
    self.app = app; self.window = window; self.url = url; self.chat = chat
    self.extra = extra
  }
}

public struct Capture: Codable, Equatable {
  public var method: String
  public var confidence: Double?
  public init(method: String, confidence: Double? = nil) { self.method = method; self.confidence = confidence }
}

public struct Record: Codable, Equatable {
  public var id: String
  public var schema: Int
  public var device: String
  public var source: String
  public var source_ref: String?
  public var people: [String]?
  public var kind: String
  public var t_start: String
  public var t_end: String?
  public var context: RecordContext?
  public var title: String
  public var body: String
  public var capture: Capture
  public var sensitivity: String

  public init(device: String, source: String, kind: String, start: Date, end: Date? = nil,
              context: RecordContext?, title: String, body: String, capture: Capture,
              sourceRef: String? = nil, people: [String]? = nil) {
    self.id = ULID.make(start)
    self.schema = 1
    self.device = device
    self.source = source
    self.source_ref = sourceRef
    self.people = people
    self.kind = kind
    self.t_start = LocalTime.iso(start)
    self.t_end = end.map { LocalTime.iso($0) }
    self.context = context
    self.title = Text.clamp(title, 200)
    self.body = body
    self.capture = capture
    self.sensitivity = "normal"
  }
}

public enum ULID {
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  // 同一毫秒内按生成顺序递增（monotonic ULID），按 id 排序取"最新"时不会排反。
  // 按时间记住最近一次的随机部分：用记录开始时间和当前时间交替生成时也能各自递增。
  nonisolated(unsafe) private static var recent: [UInt64: [Int]] = [:]
  nonisolated(unsafe) private static var order: [UInt64] = []
  private static let lock = NSLock()

  public static func make(_ date: Date = Date()) -> String {
    let time = UInt64(max(0, date.timeIntervalSince1970 * 1000))
    lock.lock(); defer { lock.unlock() }
    var rand: [Int]
    if let last = recent[time] {
      rand = last
      var i = rand.count - 1
      while i >= 0 && rand[i] == 31 { rand[i] = 0; i -= 1 }
      precondition(i >= 0, "同一毫秒内的 ULID 用尽")
      rand[i] += 1
    } else {
      rand = (0..<16).map { _ in Int.random(in: 0..<32) }
      rand[0] %= 16
    }
    // 最近用过的时间排到最后，淘汰最久没用的。
    if recent.updateValue(rand, forKey: time) != nil { order.removeAll { $0 == time } }
    order.append(time)
    if order.count > 256 { recent.removeValue(forKey: order.removeFirst()) }
    var t = time
    var ts = [Character](repeating: "0", count: 10)
    for i in (0..<10).reversed() { ts[i] = alphabet[Int(t % 32)]; t /= 32 }
    return String(ts) + String(rand.map { alphabet[$0] })
  }
}

public enum LocalTime {
  /// RFC 3339，带本地时区偏移，例如 2026-11-08T14:02:10+08:00
  public static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = timeZone
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
  }
}

public enum Text {
  /// 压成一行并按字符数截断。
  public static func clamp(_ s: String, _ max: Int) -> String {
    let one = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    let v = one.isEmpty ? "（无标题）" : one
    return v.count <= max ? v : String(v.prefix(max - 1)) + "…"
  }

  /// 拆成去掉首尾空白的非空行。
  public static func lines(_ s: String) -> [String] {
    s.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  public static func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) 秒" }
    if s < 3600 { return "\(s / 60) 分钟" }
    let m = (s % 3600) / 60
    return m == 0 ? "\(s / 3600) 小时" : "\(s / 3600) 小时 \(m) 分钟"
  }
}
