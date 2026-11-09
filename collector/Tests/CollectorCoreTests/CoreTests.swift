import Foundation
import Testing
@testable import CollectorCore

let t0 = Date(timeIntervalSince1970: 1_794_000_000)
func obs(_ dt: TimeInterval, _ window: String = "doc.md", app: String = "abnerworks.Typora",
         lines: [String] = [], url: String? = nil, method: String = "ax") -> Observation {
  Observation(time: t0.addingTimeInterval(dt), bundleID: app, appName: "Typora", window: window,
              url: url, lines: lines, method: method)
}

@Test func ulidFormatAndOrder() {
  let a = ULID.make(t0), b = ULID.make(t0.addingTimeInterval(1))
  #expect(a.count == 26)
  #expect(a.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
  #expect(a.prefix(10) < b.prefix(10))
}

@Test func ulidMonotonicWithinMillisecond() {
  // 和其他时间交替生成也要保持递增；并行测试也会在中间插入别的时间。
  let ids = (0..<1000).map { i -> String in _ = ULID.make(t0.addingTimeInterval(Double(i + 1))); return ULID.make(t0) }
  #expect(zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func localTimeHasOffset() {
  let s = LocalTime.iso(t0, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
  #expect(s.hasSuffix("+08:00"))
}

@Test func switchingWindowClosesSegmentAndDedupesLines() {
  let s = Segmenter(device: "mac")
  #expect(s.observe(obs(0, lines: ["第一行", "第二行"])).isEmpty)
  #expect(s.observe(obs(3, lines: ["第二行", "第三行"])).isEmpty)
  let out = s.observe(obs(6, "other.md", lines: ["新窗口"]))
  #expect(out.count == 1)
  let r = out[0]
  #expect(r.source == "mac.screen" && r.kind == "span")
  #expect(r.body == "第一行\n第二行\n第三行")
  #expect(r.title == "Typora · doc.md")
  #expect(r.context?.window == "doc.md")
  #expect(r.capture.method == "ax")
}

@Test func idleGapClosesSegment() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, lines: ["a"]))
  let out = s.observe(obs(200, lines: ["b"]))
  #expect(out.count == 1)
  #expect(out[0].body == "a")
}

@Test func shortEmptySegmentDropped() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0))
  #expect(s.observe(obs(2, "x")).isEmpty)
  _ = s.observe(obs(10, "x"))
  // 有 8 秒、没有正文：保留，记录应用使用时长
  let out = s.flush()
  #expect(out.count == 1 && out[0].body.isEmpty)
}

@Test func oversizedBodySplits() {
  var cfg = Segmenter.Config(); cfg.maxBody = 25   // 每行算 11 字符（含换行），两行放得下，三行放不下
  let s = Segmenter(device: "mac", config: cfg)
  let out = s.observe(obs(0, lines: ["aaaaaaaaaa", "bbbbbbbbbb", "cccccccccc"]))
  #expect(out.count == 1)
  #expect(out[0].body == "aaaaaaaaaa\nbbbbbbbbbb")
  #expect(s.flush().first?.body == "cccccccccc")
}

@Test func maxSpanSplits() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, lines: ["a"]))
  _ = s.observe(obs(3500, lines: ["b"]))  // 3500 秒内连续观察（每次间隔 >120 会被当成空闲，这里只测时长）
  #expect(s.currentKey != nil)
}

@Test func ocrOnlySegmentMarked() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, app: "com.tencent.xinWeChat"))
  let key = obs(0, app: "com.tencent.xinWeChat").key
  #expect(s.appendIfCurrent(key: key, lines: ["你好"], method: "ocr", time: t0).isEmpty)
  #expect(s.appendIfCurrent(key: "别的窗口", lines: ["丢弃"], method: "ocr", time: t0).isEmpty)
  _ = s.observe(obs(8, app: "com.tencent.xinWeChat"))
  let r = s.flush()[0]
  #expect(r.body == "你好")
  #expect(r.capture.method == "ocr" && r.capture.confidence == 0.7)
}

@Test func mixedAXAndOCRSegmentMarkedOCR() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, app: "com.tencent.xinWeChat", lines: ["微信"]))
  let key = obs(0, app: "com.tencent.xinWeChat").key
  _ = s.appendIfCurrent(key: key, lines: ["识别出的聊天内容"], method: "ocr", time: t0)
  let r = s.flush()[0]
  #expect(r.capture.method == "ocr" && r.capture.confidence == 0.7)
}

@Test func urlChangeIsNewSegment() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, "Zen", app: "app.zen-browser.zen", lines: ["x"], url: "https://a.example/1"))
  let out = s.observe(obs(3, "Zen", app: "app.zen-browser.zen", lines: ["y"], url: "https://a.example/2"))
  #expect(out.count == 1 && out[0].context?.url == "https://a.example/1")
}

@Test func recordJSONOmitsNilFields() throws {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, lines: ["a"]))
  let data = try JSONEncoder().encode(s.flush()[0])
  let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  #expect(obj["schema"] as? Int == 1)
  #expect(obj["t_end"] is String)
  #expect((obj["context"] as! [String: Any])["url"] == nil)
}

@Test func policyBlocksPasswordManagersAndPrivateWindows() {
  #expect(CapturePolicy.shouldSkip(bundleID: "me.proton.pass.electron", window: "Vault"))
  #expect(CapturePolicy.shouldSkip(bundleID: "app.zen-browser.zen", window: "Google — Private Browsing"))
  #expect(CapturePolicy.shouldSkip(bundleID: "com.google.Chrome", window: "新标签页 - 无痕模式"))
  #expect(!CapturePolicy.shouldSkip(bundleID: "abnerworks.Typora", window: "notes.md"))
  #expect(CapturePolicy.shouldSkip(bundleID: "x.bank", window: "", extraBlocked: ["x.bank"]))
}

@Test func clipboardSkipsConcealedAndRecordsText() {
  #expect(ClipboardPolicy.record(text: "hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
                                 app: nil, time: t0, device: "mac") == nil)
  let r = ClipboardPolicy.record(text: "第一行\n第二行", types: ["public.utf8-plain-text"], app: "com.x", time: t0, device: "mac")!
  #expect(r.kind == "event" && r.source == "mac.clipboard" && r.title == "复制 · 第一行" && r.body == "第一行\n第二行")
  #expect(ClipboardPolicy.record(text: nil, types: ["public.png"], app: nil, time: t0, device: "mac")?.title == "复制了一张图片")
  #expect(ClipboardPolicy.record(text: "  ", types: ["public.utf8-plain-text"], app: nil, time: t0, device: "mac") == nil)
}

@Test func queueDropsOldestOverCapacity() {
  let q = OutboundQueue(capacity: 2)
  let mk = { (i: Int) in Record(device: "mac", source: "mac.clipboard", kind: "event", start: t0, context: nil,
                                 title: "\(i)", body: "", capture: Capture(method: "api")) }
  q.push([mk(1), mk(2), mk(3)])
  #expect(q.count == 2 && q.dropped == 1 && q.peek(1)[0].title == "2")
  q.remove(ids: Set(q.peek(1).map(\.id)))
  #expect(q.count == 1)
}

@Test func titleClampAndDuration() {
  #expect(Text.clamp(String(repeating: "长", count: 300), 200).count == 200)
  #expect(Text.duration(59) == "59 秒")
  #expect(Text.duration(125) == "2 分钟")
  #expect(Text.duration(3720) == "1 小时 2 分钟")
}
