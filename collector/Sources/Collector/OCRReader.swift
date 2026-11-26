import AppKit
import ScreenCaptureKit
import Vision
import CollectorCore

/// 辅助功能读不到正文时的兜底（实测：微信、Zed）。截图只在内存里，识别完就丢。
/// 需要录屏权限；没有权限时什么都不做。
final class OCRReader {
  var granted: Bool { CGPreflightScreenCaptureAccess() }
  /// 截图相对窗口点尺寸的最大放大倍数（Retina 屏 2 倍即原生分辨率）。
  var maxScale: CGFloat = 2

  func requestAccess() { _ = CGRequestScreenCaptureAccess() }

  /// 找到 pid 下与 AX 窗口 frame 最接近的屏幕窗口，截图并识别。回调在任意线程。
  func recognize(pid: pid_t, frame: CGRect?, completion: @escaping (_ lines: [String], _ ms: Int) -> Void) {
    recognizeLines(pid: pid, frame: frame) { lines, _, ms in completion(lines.map(\.text), ms) }
  }

  /// 同上，带每行在窗口里的位置（点，左上为原点）和窗口尺寸，给按版面拆分的读取用（微信）。
  /// windowRank 按窗口标题挑窗口：返回 nil 的不读，数字小的优先，同级再按位置或大小挑。
  func recognizeLines(pid: pid_t, frame: CGRect?, windowRank: ((String) -> Int?)? = nil, completion: @escaping (_ lines: [OCRLine], _ window: CGSize, _ ms: Int) -> Void) {
    let started = Date()
    Task.detached(priority: .utility) {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 }
        // 不知道窗口位置时取最大的那个（主窗口），不取图片查看器、小浮窗。
        func distance(_ w: SCWindow) -> CGFloat {
          guard let f = frame else { return -w.frame.width * w.frame.height }
          return abs(w.frame.minX - f.minX) + abs(w.frame.minY - f.minY) + abs(w.frame.width - f.width) + abs(w.frame.height - f.height)
        }
        let ranked = candidates.compactMap { w in (windowRank ?? { _ in 0 })(w.title ?? "").map { (window: w, rank: $0) } }
        guard let win = ranked.min(by: { ($0.rank, distance($0.window)) < ($1.rank, distance($1.window)) })?.window else {
          completion([], .zero, 0); return
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = min(self.maxScale, 3000 / max(win.frame.width, 1))
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let W = Double(win.frame.width), H = Double(win.frame.height)
        // Vision 按从上到下返回；坐标是归一化的、原点在左下，换成窗口内的点。
        let lines = (request.results ?? []).compactMap { o -> OCRLine? in
          guard let c = o.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
          let text = c.string.trimmingCharacters(in: .whitespaces)
          guard !text.isEmpty else { return nil }
          let b = o.boundingBox
          return OCRLine(text, minX: b.minX * W, maxX: b.maxX * W, y: (1 - b.maxY) * H, height: b.height * H)
        }
        completion(lines, win.frame.size, Int(Date().timeIntervalSince(started) * 1000))
      } catch {
        completion([], .zero, Int(Date().timeIntervalSince(started) * 1000))
      }
    }
  }
}
