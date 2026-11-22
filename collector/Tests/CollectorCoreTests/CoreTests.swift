import Foundation
import Testing
@testable import CollectorCore

let t0 = Date(timeIntervalSince1970: 1_794_000_000)
func obs(_ dt: TimeInterval, _ window: String = "doc.md", app: String = "abnerworks.Typora",
         lines: [String] = [], url: String? = nil, method: String = "ax",
         editable: [[Int]: [String]] = [:]) -> Observation {
  Observation(time: t0.addingTimeInterval(dt), bundleID: app, appName: "Typora", window: window,
              url: url, lines: lines, editable: editable, method: method)
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
  #expect(s.observe(obs(16, lines: ["第二行", "第三行"])).isEmpty)
  #expect(s.observe(obs(17, "other.md", lines: ["新窗口"])).isEmpty)
  // 切去的窗口满 15 秒才写出原段。
  let out = s.observe(obs(32, "other.md"))
  #expect(out.count == 1)
  let r = out[0]
  #expect(r.source == "mac.screen" && r.kind == "span")
  #expect(r.body == "第一行\n第二行\n第三行")
  #expect(r.title == "Typora · doc.md")
  #expect(r.context?.window == "doc.md")
  #expect(r.capture.method == "ax")
}

@Test func editingOneFieldKeepsOnlyItsLatestValueAndDropsErasedDrafts() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, lines: ["第一处可搜索正文"], editable: [[0]: ["输入中"], [1]: ["稍后清空"]]))
  _ = s.observe(obs(3, lines: ["第二处可搜索正文"], editable: [[0]: ["输入中的扩写"], [2]: ["另外的编辑区"]]))
  _ = s.observe(obs(6, editable: [[0]: ["重新写的最终稿"], [1]: []]))
  let records = s.flush()
  #expect(records.map(\.body) == ["第一处可搜索正文\n第二处可搜索正文\n重新写的最终稿\n另外的编辑区"])
}

@Test func quickWindowSwitchesDropEvenWhenAXSawText() {
  let s = Segmenter(device: "mac")
  let observations = [
    obs(0, "初始文档", lines: ["可用文字"]), obs(16, "初始文档"),
    obs(17, "闪过的窗口", lines: ["一次快照"]),
    obs(18, "三秒的窗口", lines: ["三秒的文字"]), obs(21, "三秒的窗口"),
    obs(22, "四秒的窗口", lines: ["四秒的文字"]), obs(26, "四秒的窗口"),
    obs(27, "确认后的文档", lines: ["继续工作"]), obs(43, "确认后的文档"),
  ]
  let results = observations.flatMap { s.observe($0) } + s.flush()
  #expect(results.compactMap { $0.context?.window } == ["初始文档", "确认后的文档"])
  #expect(results.map(\.body) == ["可用文字", "继续工作"])
}

@Test func aShortWindowSwitchDoesNotWriteASeparateScreenRecord() {
  let s = Segmenter(device: "mac")
  let results = [
    obs(0, "短切换", lines: ["这次切换有正文"]), obs(12, "短切换"),
    obs(13, "已达到时长", lines: ["这段继续保留"]), obs(28, "已达到时长"),
    obs(29, "下一个窗口"),
  ].flatMap { s.observe($0) } + s.flush()
  #expect(results.map(\.body) == ["这段继续保留"])
}

@Test(arguments: ["com.anthropic.claudefordesktop", "com.openai.codex", "com.tencent.xinWeChat"])
func screenSegmentsForDedicatedSourcesKeepOnlyWindowMetadata(bundle: String) {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, "合成窗口", app: bundle, lines: ["窗口正文"],
                    url: "https://synthetic.example", editable: [[0]: ["输入框"]]))
  _ = s.appendIfCurrent(key: s.currentKey!, lines: ["延迟的识字结果"], method: "ocr", time: t0.addingTimeInterval(3))
  _ = s.observe(obs(18, "合成窗口", app: bundle, lines: ["后续正文"], url: "https://synthetic.example"))
  let records = s.flush()
  #expect(records.count == 1)
  #expect(records.first?.body == "")
  #expect(records.first?.context?.app == bundle)
  #expect(records.first?.context?.window == "合成窗口")
  #expect(records.first?.context?.url == nil)
  #expect(records.first?.t_end != nil)
}

@Test func capacitySplitDoesNotEmitAnIntermediateEdit() {
  var config = Segmenter.Config()
  config.maxBody = 18
  let s = Segmenter(device: "mac", config: config)
  #expect(s.observe(obs(0, lines: ["aaaaaaaaaa"], editable: [[0]: ["旧草稿"]])).isEmpty)
  let split = s.observe(obs(6, lines: ["bbbbbbbbbb"], editable: [[0]: ["最终稿"]]))
  #expect(split.map(\.body) == ["aaaaaaaaaa"])
  #expect(s.flush().map(\.body) == ["bbbbbbbbbb\n最终稿"])
}

@Test func ocrFallbackDoesNotAddTextFromAnAlreadyReadEditableArea() {
  let frame = CGRect(x: 300, y: 50, width: 600, height: 300)
  let editor = CGRect(x: 325, y: 100, width: 400, height: 160)
  let window = CGSize(width: 300, height: 150)
  #expect(ScreenTextPolicy.isEditableOCRPoint(CGPoint(x: 80, y: 40), window: window, frame: frame, editableFrames: [editor]))
  #expect(!ScreenTextPolicy.isEditableOCRPoint(CGPoint(x: 220, y: 40), window: window, frame: frame, editableFrames: [editor]))
  #expect(!ScreenTextPolicy.isEditableOCRPoint(CGPoint(x: 80, y: 40), window: window, frame: nil, editableFrames: [editor]))
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
  _ = s.observe(obs(18, "x"))
  // 有 16 秒、没有正文：保留，记录应用使用时长
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
  _ = s.observe(obs(0))
  let key = obs(0).key
  #expect(s.appendIfCurrent(key: key, lines: ["你好"], method: "ocr", time: t0).isEmpty)
  #expect(s.appendIfCurrent(key: "别的窗口", lines: ["丢弃"], method: "ocr", time: t0).isEmpty)
  _ = s.observe(obs(8))
  let r = s.flush()[0]
  #expect(r.body == "你好")
  #expect(r.capture.method == "ocr" && r.capture.confidence == 0.7)
}

@Test func mixedAXAndOCRSegmentMarkedOCR() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, lines: ["文档"]))
  let key = obs(0).key
  _ = s.appendIfCurrent(key: key, lines: ["识别出的文档内容"], method: "ocr", time: t0)
  let r = s.flush()[0]
  #expect(r.capture.method == "ocr" && r.capture.confidence == 0.7)
}

@Test func urlChangeIsNewSegment() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, "Zen", app: "app.zen-browser.zen", lines: ["x"], url: "https://a.example/1"))
  _ = s.observe(obs(16, "Zen", app: "app.zen-browser.zen", url: "https://a.example/1"))
  #expect(s.observe(obs(17, "Zen", app: "app.zen-browser.zen", lines: ["y"], url: "https://a.example/2")).isEmpty)
  let out = s.observe(obs(33, "Zen", app: "app.zen-browser.zen", url: "https://a.example/2"))
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

@Test func queueDropsOldestOverCapacity() {
  let q = OutboundQueue(capacity: 2)
  let mk = { (i: Int) in Record(device: "mac", source: "mac.clipboard", kind: "event", start: t0, context: nil,
                                 title: "\(i)", body: "", capture: Capture(method: "api")) }
  #expect(q.queuePeak == 0)
  q.push([mk(1), mk(2), mk(3)])
  #expect(q.queuePeak == 2)
  #expect(q.count == 2 && q.dropped == 1 && q.peek(1)[0].title == "2")
  q.remove(ids: Set(q.peek(1).map(\.id)))
  #expect(q.count == 1)
  #expect(q.queuePeak == 2)
  q.remove(ids: Set(q.peek(10).map(\.id)))
  #expect(q.count == 0 && q.queuePeak == 2)
}

@Test func titleClampAndDuration() {
  #expect(Text.clamp(String(repeating: "长", count: 300), 200).count == 200)
  #expect(Text.duration(59) == "59 秒")
  #expect(Text.duration(125) == "2 分钟")
  #expect(Text.duration(3720) == "1 小时 2 分钟")
}

@Test func screenTextPolicyKeepsTextForOtherApps() {
  #expect(ScreenTextPolicy.keepsText(bundleID: "abnerworks.Typora"))
  #expect(ScreenTextPolicy.keepsText(bundleID: "com.netease.163music"))
}

@Test func hubBusyCountsOnlyRetryResponsesAndResetsOnRestart() {
  var metrics = HubDeliveryMetrics()
  #expect(metrics.hubBusy == 0)
  for status in [503, 200, 400, 503, 500, 0] { metrics.received(status: status) }
  #expect(metrics.hubBusy == 2)
  #expect(HubDeliveryMetrics().hubBusy == 0)
}

@Test func privateStatusFileKeepsPermissionsAcrossReplacement() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("status.json")
  for text in ["first", "updated"] {
    try PrivateFile.write(Data(text.utf8), to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == text)
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["status.json"])
}

/// 2026-11-18：瞄一眼别的窗口（不足 15 秒）又回来，算同一段，不拆成两条。
@Test func briefDetourReturnsToTheSameScreenRecord() {
  let s = Segmenter(device: "mac")
  let results = [
    obs(0, "长文档", lines: ["第一段正文"]), obs(40, "长文档"),
    obs(41, "瞄一眼", lines: ["插段文字"]), obs(48, "瞄一眼"),
    obs(49, "长文档", lines: ["第二段正文"]), obs(90, "长文档"),
    obs(91, "下一个窗口", lines: ["新的正文"]), obs(110, "下一个窗口"),
  ].flatMap { s.observe($0) } + s.flush()
  #expect(results.compactMap { $0.context?.window } == ["长文档", "下一个窗口"])
  #expect(results.first?.body == "第一段正文\n第二段正文")
  #expect(results.first.map { $0.t_end! } == LocalTime.iso(t0.addingTimeInterval(90)))
}

@Test func heldSegmentIsWrittenOnFlushAndAfterIdle() {
  let s = Segmenter(device: "mac")
  _ = s.observe(obs(0, "原窗口", lines: ["原正文"])); _ = s.observe(obs(20, "原窗口"))
  _ = s.observe(obs(21, "插段"))
  #expect(s.flush().compactMap { $0.context?.window } == ["原窗口"])
  _ = s.observe(obs(300, "原窗口", lines: ["原正文"])); _ = s.observe(obs(320, "原窗口"))
  _ = s.observe(obs(321, "插段"))
  #expect(s.observe(obs(500, "原窗口")).compactMap { $0.context?.window } == ["原窗口"])
}
