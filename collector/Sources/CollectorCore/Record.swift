import Foundation

// 与 schema/record.schema.json 对应的子集；采集端只产出这些字段。

public struct RecordContext: Codable, Equatable {
  public var app: String?
  public var window: String?
  public var url: String?
  public init(app: String? = nil, window: String? = nil, url: String? = nil) {
    self.app = app; self.window = window; self.url = url
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
  public var kind: String
  public var t_start: String
  public var t_end: String?
  public var context: RecordContext?
  public var title: String
  public var body: String
  public var capture: Capture
  public var sensitivity: String

  public init(device: String, source: String, kind: String, start: Date, end: Date? = nil,
              context: RecordContext?, title: String, body: String, capture: Capture) {
    self.id = ULID.make(start)
    self.schema = 1
    self.device = device
    self.source = source
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
  public static func make(_ date: Date = Date()) -> String {
    var t = UInt64(max(0, date.timeIntervalSince1970 * 1000))
    var ts = [Character](repeating: "0", count: 10)
    for i in (0..<10).reversed() { ts[i] = alphabet[Int(t % 32)]; t /= 32 }
    var r = String(ts)
    for _ in 0..<16 { r.append(alphabet[Int.random(in: 0..<32)]) }
    return r
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
