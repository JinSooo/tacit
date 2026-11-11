import CoreText
import Foundation

/// Phosphor 图标字体（Resources/Phosphor）的码位，只收录查看窗口和菜单栏实际用到的。
/// 码位取自官方包的 Fonts/regular/style.css，Regular 和 Fill 两套字体码位相同。
public enum PhosphorGlyphs {
  public static let table: [(name: String, code: UInt32)] = [
    ("app-window", 0xE5DA),
    ("arrow-circle-right", 0xE02E),
    ("arrow-clockwise", 0xE036),
    ("arrow-right", 0xE06C),
    ("arrow-up-right", 0xE092),
    ("arrows-left-right", 0xE0A0),
    ("arrows-out", 0xE0A2),
    ("asterisk", 0xE0AA),
    ("browser", 0xE0F4),
    ("calendar-blank", 0xE10A),
    ("caret-left", 0xE138),
    ("caret-right", 0xE13A),
    ("chat-circle", 0xE168),
    ("check", 0xE182),
    ("check-circle", 0xE184),
    ("circle-dashed", 0xE602),
    ("clipboard-text", 0xE198),
    ("clock", 0xE19A),
    ("clock-counter-clockwise", 0xE1A0),
    ("code", 0xE1BC),
    ("copy", 0xE1CA),
    ("cpu", 0xE610),
    ("database", 0xE1DE),
    ("eye", 0xE220),
    ("eye-slash", 0xE224),
    ("file", 0xE230),
    ("file-arrow-down", 0xE232),
    ("file-magnifying-glass", 0xE238),
    ("file-text", 0xE23A),
    ("flag-checkered", 0xEA38),
    ("folder", 0xE24A),
    ("folder-dashed", 0xE8F8),
    ("funnel-simple", 0xE268),
    ("gear-six", 0xE272),
    ("git-branch", 0xE278),
    ("git-merge", 0xE280),
    ("globe", 0xE288),
    ("hourglass", 0xE2B2),
    ("leaf", 0xE2DA),
    ("link", 0xE2E2),
    ("list-bullets", 0xE2F2),
    ("lock", 0xE2FA),
    ("magnifying-glass", 0xE30C),
    ("magnifying-glass-plus", 0xE310),
    ("minus-circle", 0xE32C),
    ("moon-stars", 0xE58E),
    ("note-pencil", 0xE34C),
    ("pause", 0xE39E),
    ("pause-circle", 0xE3A0),
    ("pencil-simple", 0xE3B4),
    ("pencil-simple-line", 0xEBC6),
    ("play", 0xE3D0),
    ("plugs-connected", 0xEB5A),
    ("plus", 0xE3D4),
    ("question", 0xE3E8),
    ("record", 0xE3EE),
    ("seal-check", 0xE606),
    ("shield-check", 0xE40C),
    ("sidebar-simple", 0xEC24),
    ("sliders-horizontal", 0xE434),
    ("sparkle", 0xE6A2),
    ("sun-horizon", 0xE5B6),
    ("terminal-window", 0xEAE8),
    ("trash", 0xE4A6),
    ("tray", 0xE4AA),
    ("user", 0xE4C2),
    ("users", 0xE4D6),
    ("warning", 0xE4E0),
    ("warning-circle", 0xE4E2),
    ("waveform", 0xE802),
    ("wrench", 0xE5D4),
    ("x", 0xE4F6),
    ("x-circle", 0xE4F8),
  ]
  private static let codes = Dictionary(table.map { ($0.name, $0.code) }, uniquingKeysWith: { a, _ in a })

  /// 名字对应的字符；表里没有时返回空串（不画任何东西）。
  public static func character(_ name: String) -> String {
    guard let code = codes[name], let scalar = Unicode.Scalar(code) else { return "" }
    return String(Character(scalar))
  }

  /// 图标在 size × size 方框里的路径（y 轴向上）。Phosphor 的设计方框是一个 em：基线下 0.0625em 到基线上 0.9375em，
  /// 把基线抬到方框底边上方 descent 处，设计方框就正好填满整个方框，墨迹居中。
  public static func path(_ name: String, font: CTFont) -> CGPath? {
    guard let code = codes[name], code <= 0xFFFF else { return nil }
    var char = UniChar(code), glyph = CGGlyph(0)
    guard CTFontGetGlyphsForCharacters(font, &char, &glyph, 1) else { return nil }
    var shift = CGAffineTransform(translationX: 0, y: CTFontGetDescent(font))
    return CTFontCreatePathForGlyph(font, glyph, &shift)
  }
}
