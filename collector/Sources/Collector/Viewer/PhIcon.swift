import AppKit
import CoreText
import SwiftUI
import CollectorCore

/// Phosphor 图标字体（MIT，随 app 放在 Resources/Phosphor）。笔画用 Regular，原来用实心符号的地方用 Fill。
enum Phosphor {
  static let regular = "Phosphor"
  static let fill = "Phosphor-Fill"

  /// 启动时注册到本进程；失败只记日志，图标位置会空着。
  static func register() {
    guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Phosphor") else { return }
    for file in ["Phosphor.ttf", "Phosphor-Fill.ttf"] {
      let url = dir.appendingPathComponent(file)
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        let e = error?.takeRetainedValue()
        // 重复注册（同一进程再调一次）不算失败。
        if let e, CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue { continue }
        NSLog("record-anything: 注册图标字体失败 \(url.path)：\(e.map { String(describing: $0) } ?? "未知错误")")
      }
    }
  }
}

extension Phosphor {
  private static var cache: [String: NSImage] = [:]

  /// size × size 的模板图，墨迹在方框里居中。按名字、字重、尺寸缓存；只在主线程调用。
  static func image(_ name: String, fill: Bool = false, size: CGFloat) -> NSImage {
    let key = "\(name)|\(fill)|\(size)"
    if let hit = cache[key] { return hit }
    let font = CTFontCreateWithName((fill ? Phosphor.fill : Phosphor.regular) as CFString, size, nil)
    let path = PhosphorGlyphs.path(name, font: font)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
      guard let path, let cg = NSGraphicsContext.current?.cgContext else { return true }
      cg.addPath(path); cg.setFillColor(.black); cg.fillPath()
      return true
    }
    image.isTemplate = true
    cache[key] = image
    return image
  }
}

/// 单个 Phosphor 图标。用 `.foregroundStyle` 上色，尺寸只认 `size`（外层 `.font` 不影响它）。
/// 画成墨迹居中的模板图，在任何容器里都按方框居中，不依赖字体行高。和文字按基线对齐时，
/// 基线取方框顶下 0.9375em，和原来用 Text 画时一致。
/// 工具栏按钮里图标偏上（2026-11-10 用户报告）的根因不在这里，而是构建记错了 SDK 版本，见 swift.sh。
/// 图标对辅助功能隐藏，名字由外层按钮的 `.accessibilityLabel` 或 Label 的文字提供。
struct PhIcon: View {
  let name: String
  var fill = false
  var size: CGFloat = 13

  init(_ name: String, fill: Bool = false, size: CGFloat = 13) {
    self.name = name
    self.fill = fill
    self.size = size
  }

  var body: some View {
    Image(nsImage: Phosphor.image(name, fill: fill, size: size))
      .renderingMode(.template)
      .frame(width: size, height: size)
      .alignmentGuide(.firstTextBaseline) { $0.height * 0.9375 }
      .alignmentGuide(.lastTextBaseline) { $0.height * 0.9375 }
      .accessibilityHidden(true)
  }
}

/// 工具栏按钮里图标的统一尺寸，和系统工具栏符号看起来一样大。
extension PhIcon {
  static let toolbar: CGFloat = 19
}
