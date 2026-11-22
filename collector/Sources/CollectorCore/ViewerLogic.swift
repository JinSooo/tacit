import Foundation

/// 客户端展示用的纯逻辑：时间解析与格式、连续片段合并、泳道归类、日记章节排布。

/// 录音对话来源（Mac 与手机录音采用同一套对话展示规则）。
public enum AudioSource {
  public static func isAudio(_ source: String) -> Bool {
    source == "mac.audio" || source == "android.audio"
  }
}

/// 记录标题的显示写法。采集端存的标题是"应用 · 窗口""复制 · 文字""对话 · 时间 · 人""微信 · 会话 · 发言人"，
/// 界面上不用中间点拼接：旁边已经有应用图标时去掉应用名，其余前缀改成冒号。空标题返回 nil，由调用方用来源名代替。
public enum RecordTitles {
  public static func display(_ raw: String, source: String, appShown: Bool = false) -> String? {
    let t = raw.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return nil }
    // 对话标题里是转写当时的说话人编号（"说话人 OK"），对人没有意义；有总结时由调用方换成总结标题。
    if source == "mac.audio" { return "对话" }
    if source == "android.audio" { return "手机录音" }
    if source == "android.notification" || source == "android.usage" { return t }
    let parts = t.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard parts.count > 1 else { return parts.first ?? t }
    let head = parts[0], rest = parts.dropFirst().joined(separator: "，")
    switch source {
    case "mac.screen", "mac.app":
      let window = parts.dropFirst().filter { $0 != head && $0 != "无标题" && $0 != "（无标题）" }.joined(separator: "，")
      if window.isEmpty { return head }
      return appShown ? window : "\(head)：\(window)"
    case "mac.wechat":
      // 微信 · 会话 · 发言人：会话名在前，发言人跟在冒号后。
      return parts.count >= 3 ? "\(parts[1])：\(parts.dropFirst(2).joined(separator: "，"))" : (appShown ? rest : "微信：\(rest)")
    default:
      return "\(head)：\(rest)"
    }
  }
}

/// 试听片段下面的说明。一段模糊的录音很难凭音色认出是谁，所以带上时间和他当时说的话。
public enum SampleNote {
  public static func line(stamp: String?, said: String?) -> String {
    let quote = said?.trimmingCharacters(in: .whitespaces)
    switch (stamp, quote?.isEmpty == false ? quote : nil) {
    case let (.some(stamp), .some(quote)): return "\(stamp)，当时说：\(quote)"
    case let (.some(stamp), nil): return "\(stamp) 录到的"
    case (nil, _): return ""
    }
  }
}

public enum ViewerTime {
  private static let plain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
  private static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
  }()
  private static let lock = NSLock()

  /// hub 里既有 `2026-11-09T12:20:55+09:00`，也有 `2026-11-09T03:16:24.791Z`。
  /// 时间线绘制时会对同一批时间串反复解析，ISO8601DateFormatter 每次都很贵；按原串缓存结果，超量时整体清空。
  private static var cache: [String: Date?] = [:]
  public static func parse(_ s: String) -> Date? {
    lock.lock(); defer { lock.unlock() }
    if let hit = cache[s] { return hit }
    let date = plain.date(from: s) ?? fractional.date(from: s)
    if cache.count >= 20_000 { cache.removeAll(keepingCapacity: true) }
    cache[s] = date
    return date
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
  /// 这几条是同一场对话（被静音切开的几段），列表里一场一行。
  public let conversation: ConversationRef?
  public init(records: [HistoryRecord], conversation: ConversationRef? = nil) { self.records = records; self.conversation = conversation }
  public var id: String { records[0].id }
  public var newest: HistoryRecord { records[0] }
  public var start: Date { records.last!.start }
  public var end: Date? { records.compactMap { $0.end ?? $0.start }.max() }
  public var seconds: TimeInterval { records.reduce(0) { $0 + $1.seconds } }
}

public enum RecordRuns {
  /// records 需按开始时间从新到旧排列。相邻两条间隔不超过 gap 秒才合并。
  /// 属于同一场对话的 mac.audio 记录不管中间夹着什么，都并进这场对话第一次出现的那一行（用户报告：一场面试被切成五条）。
  public static func collapse(_ records: [HistoryRecord], gap: TimeInterval = 300, conversations: [ConversationRef] = []) -> [RecordRun] {
    let owner = Dictionary(conversations.flatMap { c in c.recordIds.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
    var runs: [[HistoryRecord]] = [], owners: [ConversationRef?] = [], placed: [String: Int] = [:]
    for r in records {
      if AudioSource.isAudio(r.source), let c = owner[r.id] {
        if let i = placed[c.id] { runs[i].append(r) } else { placed[c.id] = runs.count; runs.append([r]); owners.append(c) }
        continue
      }
      if owners.last == .some(nil), var last = runs.last, let newer = last.last, newer.source == r.source, newer.title == r.title,
         newer.start.timeIntervalSince(r.end ?? r.start) <= gap {
        last.append(r); runs[runs.count - 1] = last
      } else {
        runs.append([r]); owners.append(nil)
      }
    }
    return zip(runs, owners).map { RecordRun(records: $0, conversation: $1) }
  }
}

/// 菜单栏面板的最近记录：相邻的同一件事合成一行（用户报告：同一个微信聊天的几条消息分开列，占满了面板）。
/// 同一应用的窗口、浏览器记录不按标题拆行；微信按聊天合并。
public enum RecentRuns {
  /// records 按开始时间从新到旧排列；最多返回 limit 行，每行里新的在前。
  public static func group(_ records: [HistoryRecord], gap: TimeInterval = 300, limit: Int = 5) -> [[HistoryRecord]] {
    var out: [[HistoryRecord]] = []
    var i = 0
    while i < records.count {
      let r = records[i]
      if let run = out.last, joins(r, run), run.last!.start.timeIntervalSince(r.end ?? r.start) <= gap {
        out[out.count - 1].append(r)
      } else {
        if out.count == limit { break }
        out.append([r])
      }
      i += 1
    }
    return out
  }

  public static func chat(_ run: [HistoryRecord]) -> String? {
    run.lazy.compactMap { $0.contextText("chat") }.first
  }

  static func joins(_ r: HistoryRecord, _ run: [HistoryRecord]) -> Bool {
    // Agent 会话没有应用，按同一来源、同一仓库或目录合并（用户截图：连着 4 次提交各占一行）。
    if r.contextText("app") == nil, let place = r.contextText("repo") ?? r.contextText("cwd") {
      return run.allSatisfy { $0.source == r.source && $0.contextText("app") == nil && ($0.contextText("repo") ?? $0.contextText("cwd")) == place }
    }
    guard let app = r.contextText("app"), run.allSatisfy({ $0.contextText("app") == app }) else { return false }
    switch (r.contextText("chat"), chat(run)) {
    case let (c?, rc?): return c.filter { !$0.isWhitespace } == rc.filter { !$0.isWhitespace }
    case (_?, nil): return run.allSatisfy { $0.source == "mac.screen" }
    case (nil, _?): return r.source == "mac.screen"
    case (nil, nil):
      let windows = ["mac.screen", "mac.browser"]
      if windows.contains(r.source), run.allSatisfy({ windows.contains($0.source) }) { return true }
      return r.source == run[0].source && r.title == run[0].title
    }
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
    case "mac.screen", "mac.app", "android.usage": return .screen
    case "mac.browser": return .browser
    case "claude_code.session", "codex.session": return .agent
    case "mac.shell", "mac.git": return .terminal
    case "mac.audio", "android.audio", "mac.calendar", "mac.wechat", "android.notification": return .voice
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

/// “其实是…”菜单的内容。发言人是一段一段攒出来的：每次“填名字…”都会新建一条，所以同一个人会有好几条记录；
/// 还没确认的里绝大多数只出现过一两次、总共两三秒，是识别误差，不该挤进菜单。
public enum SpeakerMenu {
  public struct Entry: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let conversations: Int
    public let seconds: Double
  }

  /// 已确认的人：同名只留一条（取出现次数最多、时长最长的那条作为合并目标）。
  public static func known(_ speakers: [Speaker], excluding id: String?) -> [Entry] {
    var best: [String: Entry] = [:]
    for s in speakers where s.confirmed.value && s.id != id {
      let name = s.display.trimmingCharacters(in: .whitespaces)
      let e = Entry(id: s.id, name: name, conversations: s.conversations, seconds: s.seconds)
      if let old = best[name], (old.conversations, old.seconds) >= (e.conversations, e.seconds) { continue }
      best[name] = e
    }
    return best.values.sorted { ($0.conversations, $0.seconds) > ($1.conversations, $1.seconds) }
  }

  /// 还没确认的声音：只列出现过 2 段对话或累计 30 秒以上的，按活跃程度排，最多 limit 条。
  public static func unknown(_ speakers: [Speaker], excluding id: String?, limit: Int = 12) -> [Entry] {
    speakers.filter { !$0.confirmed.value && $0.id != id && ($0.conversations >= 2 || $0.seconds >= 30) }
      .sorted { ($0.conversations, $0.seconds) > ($1.conversations, $1.seconds) }
      .prefix(limit)
      .map { Entry(id: $0.id, name: $0.display, conversations: $0.conversations, seconds: $0.seconds) }
  }

  /// “填名字…”时如果这个名字已经有人用了，就直接并到他身上，不再新建一条同名的。
  public static func match(_ name: String, in speakers: [Speaker]) -> Speaker? {
    let key = name.trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return speakers.filter { $0.confirmed.value && $0.display.trimmingCharacters(in: .whitespaces) == key }
      .max { ($0.conversations, $0.seconds) < ($1.conversations, $1.seconds) }
  }
}


/// 待确认操作按按钮的理想尺寸排版；中文标签不能为挤进同一行而被拆开。
public enum PendingActionRows {
  public static func arrange(_ sizes: [CGSize], width: CGFloat, gap: CGFloat = 8) -> (size: CGSize, points: [CGPoint]) {
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
    var points: [CGPoint] = []
    for size in sizes {
      if x > 0 && x + size.width > width { x = 0; y += rowHeight + gap; rowHeight = 0 }
      points.append(CGPoint(x: x, y: y))
      usedWidth = max(usedWidth, x + size.width)
      rowHeight = max(rowHeight, size.height)
      x += size.width + gap
    }
    return (CGSize(width: width.isFinite ? width : usedWidth, height: y + rowHeight), points)
  }
}
