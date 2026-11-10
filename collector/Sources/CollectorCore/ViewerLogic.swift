import Foundation

/// 客户端展示用的纯逻辑：时间解析与格式、连续片段合并、泳道归类、日记章节排布。

public enum ViewerTime {
  private static let plain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
  private static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
  }()
  private static let lock = NSLock()

  /// hub 里既有 `2026-11-09T12:20:55+09:00`，也有 `2026-11-09T03:16:24.791Z`。
  public static func parse(_ s: String) -> Date? {
    lock.lock(); defer { lock.unlock() }
    return plain.date(from: s) ?? fractional.date(from: s)
  }

  /// 本地日历中某一天的 [00:00, 次日 00:00)。
  public static func dayBounds(_ day: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
    let start = calendar.startOfDay(for: day)
    return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
  }

  /// hub 的 `to` 是闭区间（t_start <= to），取次日零点前 1 毫秒。
  public static func dayQuery(_ day: Date, calendar: Calendar = .current) -> (from: String, to: String) {
    let b = dayBounds(day, calendar: calendar)
    let to = b.end.addingTimeInterval(-0.001)
    let f = ISO8601DateFormatter()
    f.timeZone = calendar.timeZone
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (f.string(from: b.start), f.string(from: to))
  }

  /// 日记里的 "HH:mm" 换成当天的时刻；"24:00" / 早于开始的结束时间视为次日。
  public static func clockOnDay(_ hhmm: String, day: Date, calendar: Calendar = .current) -> Date? {
    let parts = hhmm.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0...24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
    return calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(parts[0] * 3600 + parts[1] * 60))
  }
}

public enum ViewerFormat {
  public static func clock(_ d: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
  }

  public static func duration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s) 秒" }
    let m = s / 60
    if m < 60 { return "\(m) 分钟" }
    return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分"
  }

  /// 紧凑写法：9 小时 25 分、42 分、30 秒。
  public static func compact(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s) 秒" }
    let m = s / 60
    return m < 60 ? "\(m) 分" : (m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分")
  }

  public static func minutes(_ m: Int) -> String {
    m < 60 ? "\(m) 分钟" : (m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分")
  }

  public static func relative(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "暂无活动" }
    let m = Int(max(0, now.timeIntervalSince(date)) / 60)
    if m < 1 { return "刚刚" }
    if m < 60 { return "\(m) 分钟前" }
    if m < 1440 { return "\(m / 60) 小时前" }
    return "\(m / 1440) 天前"
  }

  public static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return "今天" }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "昨天" }
    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
    let year = c.year != calendar.component(.year, from: now) ? "\(c.year!) 年 " : ""
    return "\(year)\(c.month!) 月 \(c.day!) 日"
  }

  public static func weekday(_ day: Date, calendar: Calendar = .current) -> String {
    "星期" + ["日", "一", "二", "三", "四", "五", "六"][calendar.component(.weekday, from: day) - 1]
  }

  public static func bytes(_ n: Int) -> String {
    n < 1024 ? "\(n) B" : n < 1_048_576 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / 1_048_576)
  }
}

/// 一条或多条相邻、同来源、同标题的记录，列表里合并成一行显示（记录本身不变）。
public struct RecordRun: Identifiable, Hashable, Sendable {
  public let records: [HistoryRecord]  // 新的在前
  public init(records: [HistoryRecord]) { self.records = records }
  public var id: String { records[0].id }
  public var newest: HistoryRecord { records[0] }
  public var start: Date { records.last!.start }
  public var end: Date? { records.compactMap { $0.end ?? $0.start }.max() }
  public var seconds: TimeInterval { records.reduce(0) { $0 + $1.seconds } }
}

public enum RecordRuns {
  /// records 需按开始时间从新到旧排列。相邻两条间隔不超过 gap 秒才合并。
  public static func collapse(_ records: [HistoryRecord], gap: TimeInterval = 300) -> [RecordRun] {
    var runs: [[HistoryRecord]] = []
    for r in records {
      if var last = runs.last, let newer = last.last, newer.source == r.source, newer.title == r.title,
         newer.start.timeIntervalSince(r.end ?? r.start) <= gap {
        last.append(r); runs[runs.count - 1] = last
      } else {
        runs.append([r])
      }
    }
    return runs.map(RecordRun.init)
  }
}

/// 搜索结果里命中位置附近的一段正文，压成一行。
public struct SearchSnippet: Equatable, Sendable {
  public let before: String
  public let match: String
  public let after: String

  /// 不区分大小写找第一个命中；前后各留 radius 个字符，被截断的一侧加省略号。没命中返回 nil。
  public static func make(_ body: String, query: String, radius: Int = 36) -> SearchSnippet? {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return nil }
    let text = body.split(whereSeparator: \.isNewline).joined(separator: " ")
      .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
    let lo = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
    let hi = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
    return SearchSnippet(before: (lo > text.startIndex ? "…" : "") + text[lo..<r.lowerBound],
                         match: String(text[r]),
                         after: text[r.upperBound..<hi] + (hi < text.endIndex ? "…" : ""))
  }
}

/// History 列表里的一块：一段活动和它当前可见的记录（新的在前）。
public struct SegmentBlock: Identifiable, Hashable, Sendable {
  public let segment: HistorySegment
  public let records: [HistoryRecord]
  public init(segment: HistorySegment, records: [HistoryRecord]) { self.segment = segment; self.records = records }
  public var id: String { segment.id }
}

public enum SegmentBlocks {
  /// 把 hub 给的活动段和当天读到的记录对上，按开始时间从新到旧排列。
  /// visible 不为 nil 时只保留其中的记录，一条都不剩的段不显示。
  /// 不在任何段里的记录（两次读取之间新到的）各自成一段，不让记录从列表里消失。
  public static func join(_ segments: [HistorySegment], records: [HistoryRecord], visible: Set<String>? = nil) -> [SegmentBlock] {
    let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let keep = { (id: String) in visible?.contains(id) ?? true }
    var covered = Set<String>()
    var blocks: [SegmentBlock] = []
    for s in segments {
      covered.formUnion(s.recordIds)
      let rows = s.recordIds.compactMap { byID[$0] }.filter { keep($0.id) }
      if !rows.isEmpty { blocks.append(SegmentBlock(segment: s, records: rows.sorted { ($0.start, $0.id) > ($1.start, $1.id) })) }
    }
    for r in records where !covered.contains(r.id) && keep(r.id) {
      let s = HistorySegment(id: "r:\(r.id)", kind: "app", startMs: r.start.timeIntervalSince1970 * 1000,
                             endMs: (r.end ?? r.start).timeIntervalSince1970 * 1000, thread: nil,
                             apps: [.init(app: r.contextText("app"), source: r.source, records: 1, seconds: r.seconds)],
                             activeSeconds: r.seconds, recordIds: [r.id], privateCount: r.sensitivity == "private" ? 1 : 0)
      blocks.append(SegmentBlock(segment: s, records: [r]))
    }
    return blocks.sorted { ($0.segment.startMs, $0.id) > ($1.segment.startMs, $1.id) }
  }
}

/// History 列表里一行：一段活动，或者连续几段零碎活动折成的一行。
public enum SegmentListItem: Identifiable, Hashable, Sendable {
  case single(SegmentBlock)
  case minor([SegmentBlock])
  public var id: String {
    switch self {
    case .single(let b): return b.id
    case .minor(let bs): return "minor:" + (bs.first?.id ?? "")
    }
  }
  public var start: Date {
    switch self {
    case .single(let b): return b.segment.start
    case .minor(let bs): return bs.first?.segment.start ?? .distantPast
    }
  }
}

public enum SegmentFold {
  /// 零碎段：还没归入线程、最多 2 条记录、活跃不到 2 分钟（比如顺手切到音乐、通知窗口）。
  public static func isMinor(_ b: SegmentBlock) -> Bool {
    b.segment.thread == nil && b.records.count <= 2 && b.segment.activeSeconds < 120
  }

  /// 连续至少 minRun 段零碎活动折成一行，不足的照常单独显示；顺序不变。
  public static func fold(_ blocks: [SegmentBlock], minRun: Int = 3) -> [SegmentListItem] {
    var out: [SegmentListItem] = [], run: [SegmentBlock] = []
    func flush() {
      if run.count >= minRun { out.append(.minor(run)) } else { out.append(contentsOf: run.map { .single($0) }) }
      run = []
    }
    for b in blocks {
      if isMinor(b) { run.append(b) } else { flush(); out.append(.single(b)) }
    }
    flush()
    return out
  }
}

/// 一天的条带图里，来源归到的泳道。
public enum Lane: Int, CaseIterable, Sendable {
  case screen, browser, agent, terminal, voice, other
  public static func of(_ source: String) -> Lane {
    switch source {
    case "mac.screen", "mac.app": return .screen
    case "mac.browser": return .browser
    case "claude_code.session", "codex.session": return .agent
    case "mac.shell", "mac.git": return .terminal
    case "mac.audio", "mac.calendar", "mac.wechat": return .voice
    default: return .other
    }
  }
  public var title: String {
    switch self {
    case .screen: return "屏幕"
    case .browser: return "浏览"
    case .agent: return "Agent"
    case .terminal: return "终端"
    case .voice: return "对话"
    case .other: return "其他"
    }
  }
}

/// 日记章节在条带上的横向排布。模型给的章节时间常有交叉（10:07–10:49 和 10:25–11:22），
/// 直接按各自时间画，色块和文字会叠在一起。这里按开始时间排，每段只占到下一段开始为止。
public enum ChapterStrip {
  public struct Slot: Equatable, Sendable {
    public let index: Int     // 在输入里的位置
    public let lo: Double
    public let hi: Double
    public let label: Double? // 留给文字的宽度；放不下就是 nil，只画色块
  }

  /// spans 是各章节在屏幕上的 [起点, 终点]（已裁到可见范围）。比 minWidth 还窄的章节不画。
  public static func layout(_ spans: [(lo: Double, hi: Double)], minWidth: Double = 1, padding: Double = 6, minLabel: Double = 28) -> [Slot] {
    let order = spans.indices.sorted { (spans[$0].lo, spans[$0].hi, $0) < (spans[$1].lo, spans[$1].hi, $1) }
    var out: [Slot] = []
    for (k, i) in order.enumerated() {
      let lo = spans[i].lo
      var hi = spans[i].hi
      if k + 1 < order.count { hi = min(hi, spans[order[k + 1]].lo) }
      guard hi - lo >= minWidth else { continue }
      let text = hi - lo - 2 * padding
      out.append(Slot(index: i, lo: lo, hi: hi, label: text >= minLabel ? text : nil))
    }
    return out
  }
}

/// 单个 WAV（16 位 PCM）取出若干段峰值，画试听样本的波形。
public enum Waveform {
  public static func peaks(wav data: Data, buckets: Int) -> [Float] {
    guard buckets > 0, data.count > 44, data.prefix(4) == Data("RIFF".utf8) else { return [] }
    var offset = 12, pcm: Range<Int>?, bits = 16, channels = 1
    while offset + 8 <= data.count {
      let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
      let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
      let body = offset + 8
      if id == "fmt ", body + 16 <= data.count {
        channels = max(1, Int(data[body + 2]) | Int(data[body + 3]) << 8)
        bits = Int(data[body + 14]) | Int(data[body + 15]) << 8
      }
      if id == "data" { pcm = body..<min(data.count, body + size); break }
      offset = body + size + (size & 1)
    }
    guard let pcm, bits == 16 else { return [] }
    let frames = pcm.count / (2 * channels)
    guard frames > 0 else { return [] }
    let per = max(1, frames / buckets)
    var out: [Float] = []
    out.reserveCapacity(buckets)
    data.withUnsafeBytes { raw in
      let base = raw.baseAddress!.advanced(by: pcm.lowerBound)
      for b in 0..<min(buckets, frames) {
        var peak: Int32 = 0
        let from = b * per, to = min(frames, from + per)
        for f in from..<to {
          let v = Int32(Int16(littleEndian: base.loadUnaligned(fromByteOffset: f * 2 * channels, as: Int16.self)))
          peak = max(peak, abs(v))
        }
        out.append(Float(peak) / 32768)
      }
    }
    let top = out.max() ?? 0
    return top > 0 ? out.map { $0 / top } : out
  }
}
