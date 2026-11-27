import AppKit
import SwiftUI
import CollectorCore

/// 圆角三级，嵌套时内层 = 外层 − 间距。
enum Radius {
  static let control: CGFloat = 6
  static let group: CGFloat = 10
  static let floating: CGFloat = 14
}

enum SourceInfo {
  private static let names: [String: String] = [
    "mac.audio": "对话", "mac.screen": "屏幕", "mac.app": "应用", "mac.clipboard": "剪贴板",
    "mac.file": "文件", "mac.calendar": "日历", "mac.wechat": "微信", "mac.shell": "终端", "mac.git": "Git",
    "mac.browser": "浏览器", "android.audio": "手机录音",
    "android.notification": "手机聊天", "android.usage": "手机应用", "manual.note": "补写",
    "manual.correction": "修正", "manual.agent": "AI 补写",
  ]
  private static let englishNames = [
    "mac.audio": "Conversation", "mac.screen": "Screen", "mac.app": "App", "mac.clipboard": "Clipboard",
    "mac.file": "File", "mac.calendar": "Calendar", "mac.wechat": "WeChat", "mac.shell": "Terminal",
    "mac.browser": "Browser", "android.audio": "Phone recording", "android.notification": "Phone chats",
    "android.usage": "Phone apps", "manual.note": "Note", "manual.correction": "Correction", "manual.agent": "AI note",
  ]
  static let order = ["mac.screen", "mac.browser"] + AgentTools.sessionSources + [
                      "mac.shell", "mac.git",
                      "mac.audio", "android.audio", "mac.calendar", "mac.wechat", "android.notification",
                      "android.usage", "mac.clipboard", "mac.file", "manual.note", "manual.agent"]
  static func name(_ s: String) -> String {
    if let tool = AgentTools.session(source: s) { return tool.label }
    return L10n.text(zh: names[s] ?? s, en: englishNames[s] ?? names[s] ?? s)
  }
  /// Phosphor 图标名（见 PhosphorGlyphs）。
  static func symbol(_ s: String) -> String {
    if let tool = AgentTools.session(source: s) { return tool.symbol }
    switch s {
    case "mac.screen", "mac.app": return "browser"
    case "mac.browser": return "globe"
    case "mac.shell": return "terminal-window"
    case "mac.git": return "git-branch"
    case "mac.clipboard": return "clipboard-text"
    case "mac.file": return "file-arrow-down"
    case "mac.calendar": return "calendar-blank"
    case "mac.wechat": return "chats-circle"
    case "mac.audio": return "microphone"
    case "android.audio": return "device-mobile-speaker"
    case "android.notification": return "chat-circle-dots"
    case "android.usage": return "device-mobile"
    case "manual.note", "manual.agent": return "pencil-simple-line"
    case "manual.correction": return "note-pencil"
    default: return "circle-dashed"
    }
  }
  static var factLabels: [(kind: String, label: String, symbol: String)] {
    [
      ("next", L10n.text(zh: "下一步", en: "Next"), "arrow-circle-right"),
      ("open", L10n.text(zh: "未决", en: "Open"), "question"),
      ("decision", L10n.text(zh: "已定", en: "Decided"), "seal-check"),
      ("inference", L10n.text(zh: "推测", en: "Inferred"), "sparkle"),
      ("rejected", L10n.text(zh: "否决", en: "Rejected"), "x-circle"),
    ]
  }
}

/// 记录里的 app 是 bundle id 时取真实应用图标，取不到再退回来源符号。
@MainActor enum AppIcons {
  private static var cache: [String: NSImage?] = [:]
  static func icon(_ bundle: String?) -> NSImage? {
    guard let bundle, bundle.contains(".") else { return nil }
    if let hit = cache[bundle] { return hit }
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
      ?? SourceApplication.substitutes[bundle].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
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
  var showsTile = false
  var symbol: String? = nil
  var body: some View {
    let bundle = AgentTools.session(source: source) == nil ? app : SourceApplication.bundle(app: app, source: source)
    if let image = AppIcons.icon(bundle) {
      Image(nsImage: image).resizable().interpolation(.high).frame(width: size + 4, height: size + 4).padding(-2)
    } else if showsTile || size >= 20 {
      // 没有应用图标时画来源符号：底色只用暖灰，和真实应用图标一样大。
      RoundedRectangle(cornerRadius: min(Radius.control, size * 0.3), style: .continuous)
        .fill(Palette.fill)
        .overlay(PhIcon(symbol ?? SourceInfo.symbol(source), size: (size * 0.62).rounded()).foregroundStyle(Palette.muted))
        .frame(width: size, height: size)
    } else {
      PhIcon(symbol ?? SourceInfo.symbol(source), size: size).foregroundStyle(Palette.muted)
    }
  }
}

extension Font {
  /// 叙述性文字用宋体：系统 serif 设计对中文标点的回退会留出大空隙，宋体自带的标点宽度正确。
  static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    AppLanguage.current == .zh ? .custom("Songti SC", size: size).weight(weight)
      : .system(size: size, weight: weight, design: .serif)
  }
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
      .hoverState($hovering, enabled: hover)
  }
}

/// 项目小标签：文件夹图标 + 名字。还没确认的项目用虚线文件夹（和待确认里"新项目"同一个图标）。
struct ProjectTag: View {
  let name: String
  var unconfirmed = false
  @ObservedObject private var language = LanguageStore.shared
  var body: some View {
    HStack(spacing: 4) {
      PhIcon(unconfirmed ? "folder-dashed" : "folder", size: 12)
      Text(name).lineLimit(1)
    }
    .font(.system(size: TextSize.caption, weight: .medium))
    .foregroundStyle(Palette.muted)
    .help(unconfirmed
      ? L10n.text(zh: "项目 \(name)，还没确认", en: "Project \(name), not yet confirmed", lang: language.resolved)
      : L10n.text(zh: "项目 \(name)", en: "Project \(name)", lang: language.resolved))
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
      .pressFeedback(configuration.isPressed)
      .opacity(enabled ? 1 : 0.5)
      .animation(Motion.quick, value: enabled)
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
      .pressFeedback(configuration.isPressed)
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
  @ObservedObject private var language = LanguageStore.shared
  var body: some View {
    VStack(spacing: 12) {
      switch kind {
      case .loading:
        DelayedProgress()
      case .error(let message, let retry):
        PhIcon("warning", size: 24).foregroundStyle(Palette.attention)
        Text(message).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).textSelection(.enabled)
        Button(L10n.text(zh: "重试", en: "Retry", lang: language.resolved), action: retry).controlSize(.small)
      case .empty(let symbol, let text):
        PhIcon(symbol, size: 32).foregroundStyle(Palette.faint)
        Text(text).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}
