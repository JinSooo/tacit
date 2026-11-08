import AppKit
import ScreenCaptureKit
import Vision

/// 辅助功能读不到正文时的兜底（实测：微信、Zed）。截图只在内存里，识别完就丢。
/// 需要录屏权限；没有权限时什么都不做。
final class OCRReader {
  var granted: Bool { CGPreflightScreenCaptureAccess() }

  func requestAccess() { _ = CGRequestScreenCaptureAccess() }

  /// 找到 pid 下与 AX 窗口 frame 最接近的屏幕窗口，截图并识别。回调在任意线程。
  func recognize(pid: pid_t, frame: CGRect?, completion: @escaping (_ lines: [String], _ ms: Int) -> Void) {
    let started = Date()
    Task.detached(priority: .utility) {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 }
        func distance(_ w: SCWindow) -> CGFloat {
          guard let f = frame else { return 0 }
          return abs(w.frame.minX - f.minX) + abs(w.frame.minY - f.minY) + abs(w.frame.width - f.width) + abs(w.frame.height - f.height)
        }
        guard let win = candidates.min(by: { distance($0) < distance($1) }) else { completion([], 0); return }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = min(2.0, 3000 / max(win.frame.width, 1))
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
          .filter { ($0.topCandidates(1).first?.confidence ?? 0) >= 0.3 }
          .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        completion(lines, Int(Date().timeIntervalSince(started) * 1000))
      } catch {
        completion([], Int(Date().timeIntervalSince(started) * 1000))
      }
    }
  }
}
