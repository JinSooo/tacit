import Foundation

public enum AudioTrack: String, Codable { case mic, sys }
public enum AudioStatus: String, Codable { case open, closed, waiting_me, skipped, done, failed }
public enum AudioError: Error { case invalidMetadata, invalidTransition, invalidPath, keychain(Int32), codec(Int32) }

public struct AudioSegment: Codable, Equatable {
  public var file: String
  public var track: AudioTrack
  public var t_start: String
  public var t_end: String
  public var dbfs: Double
  public init(file: String, track: AudioTrack, start: Date, end: Date, dbfs: Double) {
    self.file = file; self.track = track; t_start = LocalTime.iso(start); t_end = LocalTime.iso(end); self.dbfs = dbfs
  }
}

public struct AudioMetadata: Codable, Equatable {
  public var id: String
  public var t_start: String
  public var t_end: String?
  public var segments: [AudioSegment]
  public var meeting_apps: [String]
  public private(set) var status: AudioStatus
  public var updated_at: String
  public private(set) var error: String?
  public private(set) var attempts: Int?

  public init(id: String = ULID.make(), start: Date) {
    self.id = id; t_start = LocalTime.iso(start); t_end = nil; segments = []; meeting_apps = []
    status = .open; updated_at = t_start
  }
  public mutating func transition(to next: AudioStatus, at date: Date, error: String? = nil) throws {
    let allowed: Bool
    switch status {
    case .open: allowed = next == .closed && t_end != nil
    case .closed, .waiting_me: allowed = [.waiting_me, .skipped, .done, .failed].contains(next)
    case .failed: allowed = (attempts ?? 0) < 3 && [.waiting_me, .skipped, .done, .failed].contains(next)
    case .skipped, .done: allowed = false
    }
    guard allowed, next != .failed || error != nil else { throw AudioError.invalidTransition }
    if next == .failed { attempts = (attempts ?? 0) + 1 }
    self.error = next == .failed ? error : nil; status = next; updated_at = LocalTime.iso(date)
  }
  public func encoded() throws -> Data {
    try validate()
    // 未结束的 t_end 必须显式写 null，便于其他进程读取。
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    if t_end == nil { json["t_end"] = NSNull() }
    return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
  }
  public static func decode(_ data: Data) throws -> Self {
    let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
  }
  public func validate() throws {
    guard (attempts.map { (0...3).contains($0) } ?? true), status != .failed || error != nil,
          AudioPolicy.validID(id), let start = AudioPolicy.date(t_start), AudioPolicy.date(updated_at) != nil,
          status == .open ? t_end == nil : (AudioPolicy.date(t_end).map { $0 >= start } ?? false),
          segments.allSatisfy({ segment in
            segment.file.range(of: "^\(segment.track.rawValue)-[0-9]{4,}\\.enc$", options: .regularExpression) != nil &&
            segment.dbfs.isFinite && AudioPolicy.date(segment.t_start) != nil &&
            (AudioPolicy.date(segment.t_end).map { $0 >= AudioPolicy.date(segment.t_start)! } ?? false)
          }) else { throw AudioError.invalidMetadata }
  }
}

public enum AudioPolicy {
  public static func validID(_ id: String) -> Bool { id.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil }
  public static func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    return fastRFC3339(text) ?? plain.date(from: text) ?? fractional.date(from: text)
  }
  /// 只认 `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`；其他写法返回 nil 交给格式器。
  /// ISO8601DateFormatter 解析一次约 36µs，采集端扫描对话时每个时间戳都要解析，会拖慢音频队列。
  static func fastRFC3339(_ text: String) -> Date? {
    let b = Array(text.utf8)
    func num(_ i: Int, _ n: Int) -> Int? {
      guard i + n <= b.count else { return nil }
      var v = 0
      for c in b[i..<(i + n)] { guard c >= 48 && c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
      return v
    }
    guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
          let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2),
          y >= 1900, (1...12).contains(mo), d >= 1, h < 24, mi < 60, s < 60 else { return nil }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    guard d <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1] else { return nil }
    var i = 19, fraction = 0.0
    if b[i] == 46 {
      var scale = 0.1; i += 1; let start = i
      while i < b.count, b[i] >= 48 && b[i] <= 57 { fraction += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
      guard i > start else { return nil }
    }
    guard i < b.count else { return nil }
    var offset = 0
    if b[i] == 90 { i += 1 }
    else if b[i] == 43 || b[i] == 45, i + 6 == b.count, b[i + 3] == 58, let oh = num(i + 1, 2), let om = num(i + 4, 2), oh < 24, om < 60 {
      offset = (oh * 3600 + om * 60) * (b[i] == 43 ? 1 : -1); i += 6
    } else { return nil }
    guard i == b.count else { return nil }
    // 公历日期转 Unix 天数（Howard Hinnant 的 days_from_civil）。
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400, yoe = yy - era * 400
    let doy = (153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5 + d - 1
    let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
    return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + s - offset) + fraction)
  }
  // 格式器只作兜底；ISO8601DateFormatter 线程安全，复用避免每次初始化 ICU。
  private static let plain = ISO8601DateFormatter()
  private static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f
  }()
  public static func shouldDelete(_ meta: AudioMetadata, now: Date, retentionDays: Int, purgeBefore: Date? = nil) -> Bool {
    guard meta.status != .open, let end = date(meta.t_end) else { return false }
    return (retentionDays > 0 && end < now.addingTimeInterval(-Double(retentionDays) * 86400)) || purgeBefore.map { end < $0 } == true
  }
}

/// 两路共享的边界；用样本时间而不是 VAD 回调到达时间。
public struct ConversationBoundary {
  public private(set) var lastSpeechEnd: Date?
  public init() {}
  public func shouldClose(at date: Date) -> Bool { lastSpeechEnd.map { date.timeIntervalSince($0) >= 60 } ?? false }
  public mutating func observe(start: Date, end: Date) -> Bool {
    let split = shouldClose(at: start)
    lastSpeechEnd = max(lastSpeechEnd ?? end, end)
    return split
  }
  public mutating func reset() { lastSpeechEnd = nil }
}

public struct MicrophoneHealth {
  private var quietSince: Date?
  public private(set) var warning = false
  public init() {}
  public mutating func observe(dbfs: Double, start: Date, end: Date, enabled: Bool) {
    guard enabled, dbfs.isFinite, dbfs < -70 else { reset(); return }
    if quietSince == nil { quietSince = start }
    warning = end.timeIntervalSince(quietSince!) >= 600
  }
  public mutating func reset() { quietSince = nil; warning = false }
}

/// 有没有录完、等着转写的对话。扫描全部 meta.json 很慢，最多每分钟扫一次；
/// 两次扫描之间沿用上次的结论，而不是当作"没有"——同一秒里会问两次（先决定要不要同步，同步回来再决定要不要启动转写），
/// 第二次问到时扫描还在冷却中，以前会答"没有"，转写进程就再也起不来。
public struct PendingWorkScan {
  public private(set) var lastScan = Date.distantPast
  public private(set) var found = false
  public init() {}
  public mutating func check(at now: Date, interval: TimeInterval = 60, scan: () -> Bool) -> Bool {
    if now.timeIntervalSince(lastScan) >= interval { lastScan = now; found = scan() }
    return found
  }
  /// 转写进程跑完以后，要重新扫一次才知道还有没有剩下的。
  public mutating func invalidate() { lastScan = .distantPast; found = false }
}
