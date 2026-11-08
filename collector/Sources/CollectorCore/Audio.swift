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
    let f = ISO8601DateFormatter()
    if let d = f.date(from: text) { return d }
    f.formatOptions.insert(.withFractionalSeconds); return f.date(from: text)
  }
  public static func shouldDelete(_ meta: AudioMetadata, now: Date, retentionDays: Int, purgeBefore: Date? = nil) -> Bool {
    guard meta.status != .open, let end = date(meta.t_end) else { return false }
    return end < now.addingTimeInterval(-Double(retentionDays) * 86400) || purgeBefore.map { end < $0 } == true
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
