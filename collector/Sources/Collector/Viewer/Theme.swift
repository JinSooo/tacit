import AppKit
import SwiftUI
import CollectorCore

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

/// 圆角三级，嵌套时内层 = 外层 − 间距。
enum Radius {
  static let control: CGFloat = 6
  static let group: CGFloat = 10
  static let floating: CGFloat = 14
}

enum SourceInfo {
  static let names: [String: String] = [
    "mac.audio": "对话", "mac.screen": "屏幕", "mac.app": "应用", "mac.clipboard": "剪贴板", "mac.file": "文件", "mac.calendar": "日历", "mac.wechat": "微信",
    "mac.shell": "终端", "mac.git": "Git", "mac.browser": "浏览器", "claude_code.session": "Claude Code", "codex.session": "Codex",
    "manual.note": "补写", "manual.correction": "修正", "manual.agent": "AI 补写",
  ]
  static let order = ["mac.screen", "mac.browser", "claude_code.session", "codex.session", "mac.shell", "mac.git", "mac.audio",
                      "mac.calendar", "mac.wechat", "mac.clipboard", "mac.file", "manual.note", "manual.agent"]
  static func name(_ s: String) -> String { names[s] ?? s }
  /// Phosphor 图标名（见 PhosphorGlyphs）。
  static func symbol(_ s: String) -> String {
    switch s {
    case "mac.screen", "mac.app": return "browser"
    case "mac.browser": return "globe"
    case "claude_code.session": return "asterisk"
    case "codex.session": return "code"
    case "mac.shell": return "terminal-window"
    case "mac.git": return "git-branch"
    case "mac.clipboard": return "clipboard-text"
    case "mac.file": return "file-arrow-down"
    case "mac.calendar": return "calendar-blank"
    case "mac.wechat": return "chat-circle"
    case "mac.audio": return "waveform"
    case "manual.note", "manual.agent": return "pencil-simple-line"
    case "manual.correction": return "note-pencil"
    default: return "circle-dashed"
    }
  }
  static let factLabels: [(kind: String, label: String, symbol: String)] = [
    ("next", "下一步", "arrow-circle-right"), ("open", "未决", "question"), ("decision", "已定", "seal-check"),
    ("inference", "推测", "sparkle"), ("rejected", "否决", "x-circle"),
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
    } else if size >= 20 {
      // 没有应用图标时画来源符号：底色只用暖灰，和真实应用图标一样大。
      RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        .fill(Palette.fill)
        .overlay(PhIcon(SourceInfo.symbol(source), size: (size * 0.62).rounded()).foregroundStyle(Palette.muted))
        .frame(width: size, height: size)
    } else {
      PhIcon(SourceInfo.symbol(source), size: size).foregroundStyle(Palette.muted)
    }
  }
}

extension Font {
  /// 叙述性文字用宋体：系统 serif 设计对中文标点的回退会留出大空隙，宋体自带的标点宽度正确。
  static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Songti SC", size: size).weight(weight) }
  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// 透出窗口后面内容的系统材质（和以前系统侧栏一样）。铺在主窗口最底层：各页面自带不透明底色，
/// 只有侧栏下面会透出来；macOS 26 的玻璃侧栏只折射窗口自己的内容，没有这一层就看不到后面的 App。
struct BehindWindowMaterial: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .sidebar
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = material
    v.blendingMode = .behindWindow
    v.state = .followsWindowActiveState
    return v
  }
  func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension View {
  /// 内容区分组：纸面底色 + 发丝线，悬停只换底色。
  func card(_ radius: CGFloat = Radius.group, hover: Bool = false) -> some View {
    modifier(CardModifier(radius: radius, hover: hover))
  }

  func sectionTitle() -> some View {
    font(.system(size: TextSize.body, weight: .semibold)).foregroundStyle(Palette.muted)
  }
}

struct CardModifier: ViewModifier {
  let radius: CGFloat
  let hover: Bool
  @State private var hovering = false
  /// 页面是平的：分组只有底色和发丝线，悬停只换底色，不抬起、不放大。
  func body(content: Content) -> some View {
    content
      .background(hover && hovering ? Palette.fill : Palette.paperRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
      .animation(.easeOut(duration: 0.15), value: hovering)
      .onHover { if hover { hovering = $0 } }
  }
}

/// 项目小标签：文件夹图标 + 名字。还没确认的项目用虚线文件夹（和待确认里"新项目"同一个图标）。
struct ProjectTag: View {
  let name: String
  var unconfirmed = false
  var body: some View {
    HStack(spacing: 4) {
      PhIcon(unconfirmed ? "folder-dashed" : "folder", size: 12)
      Text(name).lineLimit(1)
    }
    .font(.system(size: TextSize.caption, weight: .medium))
    .foregroundStyle(Palette.muted)
    .help(unconfirmed ? "项目 \(name)，还没确认" : "项目 \(name)")
  }
}

/// 主按钮：铜绿底、白字。系统的 borderedProminent 在这里不跟随 .tint，仍是系统强调色。
struct AccentButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: TextSize.body, weight: .medium))
      .foregroundStyle(Palette.onAccent)
      .padding(.horizontal, 12).frame(minHeight: 24)
      .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
      .opacity(enabled ? 1 : 0.5)
      .contentShape(Rectangle())
  }
}
extension ButtonStyle where Self == AccentButtonStyle {
  static var accent: AccentButtonStyle { AccentButtonStyle() }
}

/// 文字链接：强调色，按下变淡。系统的 .link 固定用系统链接蓝，不跟随 .tint 和 AccentColor。
struct AccentLinkStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Palette.accent)
      .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
      .contentShape(Rectangle())
  }
}
extension ButtonStyle where Self == AccentLinkStyle {
  static var accentLink: AccentLinkStyle { AccentLinkStyle() }
}

/// 加载中 / 出错 / 空，三种状态统一的占位。
struct Placeholder: View {
  enum Kind { case loading, error(String, () -> Void), empty(String, String) }
  let kind: Kind
  var body: some View {
    VStack(spacing: 12) {
      switch kind {
      case .loading:
        ProgressView().controlSize(.small)
      case .error(let message, let retry):
        PhIcon("warning", size: 24).foregroundStyle(Palette.attention)
        Text(message).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).textSelection(.enabled)
        Button("重试", action: retry).controlSize(.small)
      case .empty(let symbol, let text):
        PhIcon(symbol, size: 32).foregroundStyle(Palette.faint)
        Text(text).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}
