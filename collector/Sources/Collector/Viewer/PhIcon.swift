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

  /// 菜单栏用的模板图，size × size。字形墨迹在 em 方框里水平居中，垂直比中心高 0.06em，画的时候压下去。
  static func image(_ name: String, fill: Bool = false, size: CGFloat) -> NSImage? {
    guard let font = NSFont(name: fill ? Phosphor.fill : Phosphor.regular, size: size) else { return nil }
    let text = NSAttributedString(string: PhosphorGlyphs.character(name), attributes: [.font: font, .foregroundColor: NSColor.black])
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
      text.draw(at: NSPoint(x: 0, y: -size * 0.06))
      return true
    }
    image.isTemplate = true
    return image
  }
}

/// 单个 Phosphor 图标。用 `.foregroundStyle` 上色，尺寸只认 `size`（外层 `.font` 不影响它）。
/// 字形墨迹比行框中心高 0.06em，下移这一点和旁边文字的视觉中心对齐。私有区字符对辅助功能隐藏，
/// 名字由外层按钮的 `.accessibilityLabel` 或 Label 的文字提供。
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
    Text(PhosphorGlyphs.character(name))
      .font(.custom(fill ? Phosphor.fill : Phosphor.regular, fixedSize: size))
      .offset(y: size * 0.06)
      .accessibilityHidden(true)
  }
}

/// 工具栏按钮里图标的统一尺寸，和系统工具栏符号看起来一样大。
extension PhIcon {
  static let toolbar: CGFloat = 19
}
