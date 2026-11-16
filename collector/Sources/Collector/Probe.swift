import AppKit
import ApplicationServices

/// 开发用探针：`Collector --probe-front [--out 文件]`。
/// 对当前前台窗口分别用默认上限和不设上限各扫一次，对比读到的字数，只输出计数，不输出任何文字内容。
func runProbe() {
  let args = CommandLine.arguments
  _ = NSApplication.shared  // ScreenCaptureKit 需要已初始化的窗口服务连接
  guard AXIsProcessTrusted() else { print("{\"error\":\"untrusted\"}"); return }
  guard let app = NSWorkspace.shared.frontmostApplication else { print("{\"error\":\"no front app\"}"); return }
  let pid = app.processIdentifier
  let warm = AXReader()
  warm.prepare(pid: pid)
  Thread.sleep(forTimeInterval: 1.0)

  func run(budget: TimeInterval, maxElements: Int) -> [String: Any] {
    let r = AXReader()
    r.budget = budget; r.maxElements = maxElements
    guard let s = r.snapshot(pid: pid) else { return ["error": "no focused window"] }
    return ["chars": s.chars, "lines": s.lines.count + s.editable.values.reduce(0) { $0 + $1.count },
            "elements": s.elements, "calls": s.calls,
            "ms": s.ms, "truncated": s.truncated]
  }
  var report: [String: Any] = ["bundle": app.bundleIdentifier ?? "?"]
  report["default"] = run(budget: 0.2, maxElements: 3000)
  report["unlimited"] = run(budget: 15, maxElements: 100_000)
  if args.contains("--ocr") {
    // 只记行数和耗时；每种分辨率连续 3 次，第一次含模型加载。
    for scale in [2.0, 1.0] {
      let o = OCRReader(); o.maxScale = CGFloat(scale)
      var runs: [[String: Int]] = []
      for _ in 0..<3 {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Int] = [:]
        o.recognize(pid: pid, frame: nil) { lines, ms in result = ["lines": lines.count, "chars": lines.reduce(0) { $0 + $1.count }, "ms": ms]; sem.signal() }
        sem.wait()
        runs.append(result)
      }
      report["ocr\(Int(scale))x"] = runs
    }
    report["ocrGranted"] = OCRReader().granted
  }
  let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
  if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    try? data.write(to: URL(fileURLWithPath: args[i + 1]))
  } else {
    print(String(data: data, encoding: .utf8)!)
  }
}
