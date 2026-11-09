import AppKit
import SwiftUI
import CollectorCore

/// 设计语言：系统材质做骨架，衬线体讲"发生了什么"，等宽数字标时间；每个来源一种固定颜色。
enum Palette {
  static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { a in
      let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    })
  }

  static func source(_ s: String) -> Color {
    switch s {
    case "mac.screen", "mac.app": return dynamic(0x5B63E8, 0x8E95FF)
    case "mac.browser": return dynamic(0x0C93A0, 0x3FCAD6)
    case "claude_code.session": return dynamic(0xD06A48, 0xEE9170)
    case "codex.session": return dynamic(0x8250E8, 0xAE8CFF)
    case "mac.shell": return dynamic(0x2B9460, 0x52CC8C)
    case "mac.git": return dynamic(0xDE6A0A, 0xFF9E45)
    case "mac.clipboard": return dynamic(0xBF8F00, 0xE9C64A)
    case "mac.file": return dynamic(0x3478C0, 0x70ADEB)
    case "mac.calendar": return dynamic(0xD83C62, 0xFF7593)
    case "mac.audio": return dynamic(0xCC3F9E, 0xF074C9)
    case "manual.note", "manual.correction": return dynamic(0xA87420, 0xDDAA4E)
    default: return dynamic(0x7A7F8C, 0x9DA3B0)
    }
  }

  /// 项目没有固定颜色时按名字取一个，同名永远同色。
  static func tag(_ key: String) -> Color {
    let hues: [(UInt32, UInt32)] = [(0x5B63E8, 0x8E95FF), (0x0C93A0, 0x3FCAD6), (0xD06A48, 0xEE9170), (0x8250E8, 0xAE8CFF),
                                     (0x2B9460, 0x52CC8C), (0xDE6A0A, 0xFF9E45), (0xD83C62, 0xFF7593), (0x3478C0, 0x70ADEB)]
    let h = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
    let pick = hues[Int(h % UInt32(hues.count))]
    return dynamic(pick.0, pick.1)
  }

  static let ink = dynamic(0x1C1B1A, 0xF2EFEA)
  static let paper = dynamic(0xFBFAF7, 0x161618)
  static let paperRaised = dynamic(0xFFFFFF, 0x1F1F22)
  static let hairline = dynamic(0xE7E3DC, 0x2E2E33)
  static let recording = dynamic(0xE5484D, 0xFF6369)
  static let accent = dynamic(0x5B63E8, 0x8E95FF)

  static let factColors: [String: Color] = [
    "decision": dynamic(0x2B9460, 0x52CC8C), "rejected": dynamic(0xC93C3C, 0xFF6B6B), "open": dynamic(0xDE8A0A, 0xFFB24A),
    "next": dynamic(0x3478C0, 0x70ADEB), "inference": dynamic(0x8250E8, 0xAE8CFF),
  ]
}

enum SourceInfo {
  static let names: [String: String] = [
    "mac.audio": "对话", "mac.screen": "屏幕", "mac.app": "应用", "mac.clipboard": "剪贴板", "mac.file": "文件", "mac.calendar": "日历",
    "mac.shell": "终端", "mac.git": "Git", "mac.browser": "浏览器", "claude_code.session": "Claude Code", "codex.session": "Codex",
    "manual.note": "补写", "manual.correction": "修正",
  ]
  static let order = ["mac.screen", "mac.browser", "claude_code.session", "codex.session", "mac.shell", "mac.git", "mac.audio",
                      "mac.calendar", "mac.clipboard", "mac.file", "manual.note"]
  static func name(_ s: String) -> String { names[s] ?? s }
  static func symbol(_ s: String) -> String {
    switch s {
    case "mac.screen", "mac.app": return "macwindow"
    case "mac.browser": return "globe"
    case "claude_code.session": return "asterisk"
    case "codex.session": return "chevron.left.forwardslash.chevron.right"
    case "mac.shell": return "terminal"
    case "mac.git": return "arrow.triangle.branch"
    case "mac.clipboard": return "doc.on.clipboard"
    case "mac.file": return "arrow.down.doc"
    case "mac.calendar": return "calendar"
    case "mac.audio": return "waveform"
    case "manual.note": return "pencil.line"
    case "manual.correction": return "pencil.and.outline"
    default: return "circle.dashed"
    }
  }
  static let factLabels: [(kind: String, label: String, symbol: String)] = [
    ("next", "下一步", "arrow.right.circle.fill"), ("open", "未决", "questionmark.circle.fill"), ("decision", "已定", "checkmark.seal.fill"),
    ("inference", "推测", "sparkle"), ("rejected", "否决", "xmark.circle.fill"),
  ]
}

/// 记录里的 app 是 bundle id 时取真实应用图标，取不到再退回来源符号。
@MainActor enum AppIcons {
  private static var cache: [String: NSImage?] = [:]
  static func icon(_ bundle: String?) -> NSImage? {
    guard let bundle, bundle.contains(".") else { return nil }
    if let hit = cache[bundle] { return hit }
    let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
    cache[bundle] = image
    return image
  }
  private static var names: [String: String?] = [:]
  static func name(_ bundle: String?) -> String? {
    guard let bundle else { return nil }
    if let hit = names[bundle] { return hit }
    let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
      // 不在运行时按系统语言读应用的 InfoPlist.strings，见 AppNames。
      ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { AppNames.systemLanguageName($0) }
    names[bundle] = name
    return name
  }
}

struct SourceGlyph: View {
  let source: String
  var app: String? = nil
  var size: CGFloat = 22
  var body: some View {
    if let image = AppIcons.icon(app) {
      Image(nsImage: image).resizable().interpolation(.high).frame(width: size + 4, height: size + 4).padding(-2)
    } else {
      let tint = Palette.source(source)
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(tint.gradient.opacity(0.16))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
        .overlay(Image(systemName: SourceInfo.symbol(source)).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(tint))
        .frame(width: size, height: size)
    }
  }
}

extension Font {
  /// 叙述性文字用宋体：系统 serif 设计对中文标点的回退会留出大空隙，宋体自带的标点宽度正确。
  static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Songti SC", size: size).weight(weight) }
  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension View {
  /// macOS 26 起用 Liquid Glass，更早的系统退回半透明材质。
  @ViewBuilder func glassCapsule(interactive: Bool = false) -> some View {
    if #available(macOS 26.0, *) {
      self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    } else {
      self.background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
  }
  @ViewBuilder func glassPanel(_ radius: CGFloat = 16) -> some View {
    if #available(macOS 26.0, *) {
      self.glassEffect(.regular, in: .rect(cornerRadius: radius))
    } else {
      self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
  }

  /// 内容区卡片：纸面底色 + 发丝线，悬停时轻微抬起。
  func card(_ radius: CGFloat = 14, hover: Bool = false) -> some View {
    modifier(CardModifier(radius: radius, hover: hover))
  }

  func sectionTitle() -> some View {
    font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase).foregroundStyle(.secondary)
  }
}

struct CardModifier: ViewModifier {
  let radius: CGFloat
  let hover: Bool
  @State private var hovering = false
  func body(content: Content) -> some View {
    content
      .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
      .shadow(color: .black.opacity(hover && hovering ? 0.10 : 0.03), radius: hover && hovering ? 14 : 3, y: hover && hovering ? 6 : 1)
      .scaleEffect(hover && hovering ? 1.006 : 1)
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
      .onHover { if hover { hovering = $0 } }
  }
}

/// 项目小标签：彩色圆点 + 名字。
struct ProjectTag: View {
  let name: String
  var unconfirmed = false
  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(Palette.tag(name)).frame(width: 6, height: 6)
      Text(name).lineLimit(1)
      if unconfirmed { Text("未确认").foregroundStyle(.tertiary) }
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(.secondary)
  }
}

/// 加载中 / 出错 / 空，三种状态统一的占位。
struct Placeholder: View {
  enum Kind { case loading, error(String, () -> Void), empty(String, String) }
  let kind: Kind
  var body: some View {
    VStack(spacing: 10) {
      switch kind {
      case .loading:
        ProgressView().controlSize(.small)
      case .error(let message, let retry):
        Image(systemName: "exclamationmark.triangle").font(.system(size: 22, weight: .light)).foregroundStyle(.orange)
        Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
        Button("重试", action: retry).controlSize(.small)
      case .empty(let symbol, let text):
        Image(systemName: symbol).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.tertiary)
        Text(text).font(.serif(15)).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}
