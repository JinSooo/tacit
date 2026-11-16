import Foundation

/// 一次对前台窗口的观察。
public struct Observation {
  public var time: Date
  public var bundleID: String
  public var appName: String
  public var window: String
  public var url: String?
  public var lines: [String]
  /// 同一窗口中同一辅助功能位置的可编辑文字。
  public var editable: [[Int]: [String]]
  public var method: String   // "ax" | "ocr" | "none"

  public init(time: Date, bundleID: String, appName: String, window: String, url: String? = nil,
              lines: [String] = [], editable: [[Int]: [String]] = [:], method: String = "ax") {
    self.time = time; self.bundleID = bundleID; self.appName = appName; self.window = window
    self.url = url; self.lines = lines; self.editable = editable; self.method = method
  }

  /// 同一应用、同一窗口标题、同一 URL 算同一段。
  public var key: String { [bundleID, window, url ?? ""].joined(separator: "\u{1F}") }
}

/// 把连续的观察合并成活动片段（mac.screen 时段记录）。
/// 规则：换应用/窗口/URL、空闲超过 idleLimit、时长达到 maxSpan、正文超过 maxBody 时结束当前段。
public final class Segmenter {
  public struct Config {
    public var idleLimit: TimeInterval = 120
    public var maxSpan: TimeInterval = 3600
    public var maxBody = 100_000
    /// 快速切换时短于这个时长的前窗不写入。手动结束时仍可保留有内容的短段。
    public var minSpan: TimeInterval = 15
    public init() {}
  }

  struct Current {
    var key: String
    var start: Date
    var last: Date
    var bundleID: String
    var appName: String
    var window: String
    var url: String?
    var lines: [String] = []
    var seen: Set<String> = []
    var editable: [[Int]: [String]] = [:]
    var chars = 0
    var methods: Set<String> = []
  }

  public let device: String
  public var config: Config
  var current: Current?

  public init(device: String, config: Config = Config()) {
    self.device = device; self.config = config
  }

  public var currentKey: String? { current?.key }

  public func observe(_ observation: Observation) -> [Record] {
    var o = observation
    if !ScreenTextPolicy.keepsText(bundleID: o.bundleID) {
      o.url = nil
      o.lines = []
      o.editable = [:]
    }
    var out: [Record] = []
    if let c = current {
      let stale = o.time.timeIntervalSince(c.last) > config.idleLimit
      if c.key != o.key || stale || o.time.timeIntervalSince(c.start) >= config.maxSpan {
        out += close(switching: c.key != o.key)
      }
    }
    if current == nil { current = begin(o) }
    current!.last = o.time
    out += append(o.lines, method: o.method, from: o)
    for (position, lines) in o.editable {
      current!.editable[position] = lines.isEmpty ? nil : lines
    }
    return out
  }

  /// OCR 是异步的：结果回来时如果已经换了窗口，就丢弃，避免把旧窗口的文字记到新段里。
  public func appendIfCurrent(key: String, lines: [String], method: String, time: Date) -> [Record] {
    guard let c = current, c.key == key, ScreenTextPolicy.keepsText(bundleID: c.bundleID) else { return [] }
    let o = Observation(time: time, bundleID: c.bundleID, appName: c.appName, window: c.window,
                        url: c.url, lines: lines, method: method)
    return append(lines, method: method, from: o)
  }

  /// 空闲、锁屏、暂停、退出时调用。
  public func flush() -> [Record] { close() }

  func begin(_ o: Observation) -> Current {
    Current(key: o.key, start: o.time, last: o.time, bundleID: o.bundleID, appName: o.appName,
            window: o.window, url: o.url)
  }

  func append(_ lines: [String], method: String, from o: Observation) -> [Record] {
    var out: [Record] = []
    var added = false
    for line in lines where !current!.seen.contains(line) {
      if current!.chars + line.count + 1 > config.maxBody && !current!.lines.isEmpty {
        // 正文容量切片时继续等待编辑完成，避免在上一片写出旧稿。
        let editable = current!.editable
        current!.editable.removeAll()
        out += close()
        current = begin(o)
        current!.editable = editable
      }
      current!.seen.insert(line)
      current!.lines.append(line)
      current!.chars += line.count + 1
      added = true
    }
    if added { current!.methods.insert(method) }
    return out
  }

  func close(switching: Bool = false) -> [Record] {
    guard let c = current else { return [] }
    current = nil
    let duration = c.last.timeIntervalSince(c.start)
    if duration < config.minSpan && (switching || (c.lines.isEmpty && c.editable.isEmpty)) { return [] }
    var bodies: [String] = []
    var lines = c.lines, seen = c.seen, chars = c.chars
    for position in c.editable.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
      for line in c.editable[position] ?? [] where seen.insert(line).inserted {
        if chars + line.count + 1 > config.maxBody && !lines.isEmpty {
          bodies.append(lines.joined(separator: "\n"))
          lines.removeAll(keepingCapacity: true)
          chars = 0
        }
        lines.append(line)
        chars += line.count + 1
      }
    }
    bodies.append(lines.joined(separator: "\n"))
    // 只要有 OCR 参与就标 ocr：这段文字可能有识别错误，下游要知道。
    let usedOCR = c.methods.contains("ocr")
    let windowName = c.window.isEmpty ? "无标题" : c.window
    return bodies.map { body in
      Record(
        device: device, source: "mac.screen", kind: "span", start: c.start, end: c.last,
        context: RecordContext(app: c.bundleID, window: c.window.isEmpty ? nil : c.window, url: c.url),
        // 时长由起止时间表达，网页单独显示，不重复写进标题。
        title: "\(c.appName) · \(windowName)", body: body,
        capture: Capture(method: usedOCR ? "ocr" : "ax", confidence: usedOCR ? 0.7 : nil)
      )
    }
  }
}
