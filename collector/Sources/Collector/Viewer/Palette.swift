import AppKit
import SwiftUI

/// 设计语言见 docs/ui.md：一个强调色（铜绿），暖灰，状态正常不上色，出问题才用胭脂。
enum Palette {
  static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { a in
      let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    })
  }

  static let accent = dynamic(0x3B7468, 0x7DB8A9)
  static let onAccent = dynamic(0xFFFFFF, 0x181716)
  /// 错误、缺权限、录音中：只染文字和小图标，不铺大面积底色。
  static let attention = dynamic(0x9D2933, 0xE58A8F)
  static let readingBody = dynamic(0x45413C, 0xCCC7C0)
  static let ink = dynamic(0x1C1B1A, 0xF2EFEA)
  /// 次要文字，对比度 ≥ 4.5。
  static let muted = dynamic(0x6E6860, 0xA8A197)
  /// 只用于图形和分隔，不用于文字。
  static let faint = dynamic(0xA39D94, 0x5E5953)
  static let paper = dynamic(0xFBFAF7, 0x181716)
  static let paperRaised = dynamic(0xFFFFFF, 0x211F1D)
  static let hairline = dynamic(0xE7E3DC, 0x2F2C29)
  /// 时间轴轨道、输入框、悬停。
  static let fill = dynamic(0xF1EEE8, 0x262422)
  // 来源、项目、事实类型不再各配一种颜色：时间轴每行写了来源名，项目和事实类型有文字和图标。
}

/// 字号只有这 5 级，一页最多用 4 级（docs/ui.md 第 3 节）。
enum TextSize {
  static let caption: CGFloat = 11
  static let body: CGFloat = 13
  static let title: CGFloat = 17
  static let heading: CGFloat = 22
  static let display: CGFloat = 26

  /// 行距：正文行高约 1.5，宋体摘要约 1.6（系统默认行高之外再加的部分）。
  static func lineSpacing(_ size: CGFloat) -> CGFloat { (size * 0.3).rounded() }
  static func serifLineSpacing(_ size: CGFloat) -> CGFloat { (size * 0.35).rounded() }
}
