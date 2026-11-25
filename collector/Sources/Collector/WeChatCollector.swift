import AppKit
import CollectorCore

/// 微信对话（默认关闭）：微信在前台时定期截它的窗口，只读聊天区，按版面拆成一条条消息。
/// 截图只在内存里，识别完就丢。每条消息按（会话、发送人、内容、最近的时间分隔）算指纹作 source_ref，
/// 中枢按 (source, source_ref) 去重；这里再留一份最近的指纹，避免同一屏反复发送。
/// 只记屏幕上看过的消息；没打开的会话、没往上翻的历史记不到。
final class WeChatCollector {
  static let bundleID = "com.tencent.xinWeChat"
  static let source = "mac.wechat"
  /// 同一窗口至少隔这么久才再截一次。
  static let interval: TimeInterval = 8

  private let device: String
  private let ocr: OCRReader
  private let send: ([Record]) -> Void
  private let queue = DispatchQueue(label: "record-anything.wechat", qos: .utility)
  // 以下只在 queue 上读写。
  private var seen: [String] = []
  private var seenSet: Set<String> = []
  /// 最近记下的消息，按（会话、发送人、时间分隔）分组，指纹没对上时比内容是否只差一两个字。
  private var recent: [String: [String]] = [:]
  private var running = false
  private var lastRun = Date.distantPast
  // 只在主线程读写，给"上次运行"用。
  private(set) var last: Date?
  private(set) var lastSummary = ""

  init(device: String, ocr: OCRReader, send: @escaping ([Record]) -> Void) {
    self.device = device; self.ocr = ocr; self.send = send
  }

  /// 在主线程调用（采集节拍里，微信在前台时）。
  func poll(pid: pid_t, frame: CGRect?) {
    queue.async { [self] in
      guard !running, Date().timeIntervalSince(lastRun) >= Self.interval, ocr.granted else { return }
      running = true; lastRun = Date()
      ocr.recognizeLines(pid: pid, frame: frame, skipFilePreviews: true) { [self] lines, size, _ in
        queue.async { [self] in
          defer { running = false }
          let now = Date()
          guard size.width > 0, let view = WeChatLayout.parse(lines, width: size.width, height: size.height) else {
            // 不是聊天界面、没有新消息时不写状态（不写 0 条，也不把旧结果配上这次的时间）。
            DispatchQueue.main.async { self.last = now; self.lastSummary = "" }
            return
          }
          let fresh = records(view, now: now)
          if !fresh.isEmpty { send(fresh) }
          DispatchQueue.main.async {
            self.last = now
            self.lastSummary = fresh.isEmpty ? "" : "“\(view.chat)”新增 \(fresh.count) 条"
          }
        }
      }
    }
  }

  /// 只在 queue 上调用。
  private func records(_ view: WeChatView, now: Date) -> [Record] {
    var out: [Record] = []
    for m in view.messages {
      let fp = WeChatLayout.fingerprint(chat: view.chat, message: m)
      guard !seenSet.contains(fp) else { continue }
      remember(fp)
      let group = [ChatNames.key(view.chat), m.fromMe ? "\u{1}me" : (m.sender ?? ""), m.shownTime].joined(separator: "\u{0}")
      if recent[group, default: []].contains(where: { WeChatLayout.sameText($0, m.text) }) { continue }
      recent[group, default: []].append(m.text)
      if recent.count > 2000 { recent.removeAll() }
      let who = m.fromMe ? "我" : (m.sender ?? "")
      var extra: [String: ContextValue] = ["sender": .string(who), "from_me": .integer(m.fromMe ? 1 : 0), "group": .integer(view.isGroup ? 1 : 0)]
      if !m.shownTime.isEmpty { extra["shown_time"] = .string(m.shownTime) }
      let at = WeChatLayout.resolve(m.shownTime, now: now) ?? now
      out.append(Record(device: device, source: Self.source, kind: "event", start: at,
                        context: RecordContext(app: Self.bundleID, chat: view.chat, extra: extra),
                        title: Text.clamp("微信 · \(view.chat) · \(who)", 200), body: m.text,
                        capture: Capture(method: "ocr", confidence: 0.7), sourceRef: "fp:" + fp))
    }
    return out
  }

  private func remember(_ fp: String) {
    seen.append(fp); seenSet.insert(fp)
    if seen.count > 5000 { for old in seen.prefix(1000) { seenSet.remove(old) }; seen.removeFirst(1000) }
  }
}
