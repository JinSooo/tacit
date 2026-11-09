import AppKit
import SwiftUI
import CollectorCore

/// 主窗口。采集端平时只在菜单栏；打开窗口时临时出现在 Dock 和 ⌘Tab 里，关掉窗口后退回菜单栏。
@MainActor final class ViewerWindow: NSObject, NSWindowDelegate {
  let store: ViewerStore
  private var window: NSWindow?

  init(store: ViewerStore) {
    self.store = store
    super.init()
  }

  func show(_ page: Page? = nil) {
    if let page { store.section = page }
    if window == nil { window = makeWindow() }
    NSApp.setActivationPolicy(.regular)
    NSApp.applicationIconImage = AppIconArt.image(size: 512)
    NSApp.mainMenu = makeMenu()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  private func makeWindow() -> NSWindow {
    let hosting = NSHostingController(rootView: RootView().environment(store))
    hosting.sceneBridgingOptions = [.toolbars, .title]
    let w = NSWindow(contentViewController: hosting)
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    w.toolbarStyle = .unified
    w.title = "Record Anything"
    w.contentMinSize = NSSize(width: 980, height: 640)
    w.setContentSize(NSSize(width: 1360, height: 880))
    w.isReleasedWhenClosed = false
    w.delegate = self
    if !w.setFrameUsingName("RecordAnythingMain") { w.center() }
    w.setFrameAutosaveName("RecordAnythingMain")
    return w
  }

  func windowWillClose(_ notification: Notification) {
    DispatchQueue.main.async {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  // MARK: 菜单

  private func makeMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
      let m = NSMenu(title: title)
      items.forEach(m.addItem)
      let host = NSMenuItem(title: title, action: nil, keyEquivalent: ""); host.submenu = m
      main.addItem(host)
    }
    func item(_ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = target; i.tag = tag; return i
    }
    // ⌘Q 只关窗口：采集端要一直在后台记录，真正退出走菜单栏图标里的"退出"。
    submenu("Record Anything", [
      item("关于 Record Anything", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
      .separator(),
      item("设置…", #selector(go(_:)), ",", target: self, tag: 5),
      .separator(),
      item("隐藏 Record Anything", #selector(NSApplication.hide(_:)), "h", target: NSApp),
      .separator(),
      item("关闭窗口（继续在后台记录）", #selector(closeWindow), "q", target: self),
    ])
    submenu("编辑", [
      item("撤销", Selector(("undo:")), "z"), item("重做", Selector(("redo:")), "z", [.command, .shift]), .separator(),
      item("剪切", #selector(NSText.cut(_:)), "x"), item("复制", #selector(NSText.copy(_:)), "c"),
      item("粘贴", #selector(NSText.paste(_:)), "v"), item("全选", #selector(NSText.selectAll(_:)), "a"),
    ])
    submenu("前往", [
      item("此刻", #selector(go(_:)), "1", target: self, tag: 0), item("History", #selector(go(_:)), "2", target: self, tag: 1),
      item("待确认", #selector(go(_:)), "3", target: self, tag: 2), item("读取记录", #selector(go(_:)), "4", target: self, tag: 3),
    ])
    submenu("窗口", [
      item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"), item("缩放", #selector(NSWindow.performZoom(_:))),
      item("关闭", #selector(NSWindow.performClose(_:)), "w"),
    ])
    return main
  }

  @objc func go(_ sender: NSMenuItem) {
    store.section = [Page.now, .history, .pending, .audit, .now, .settings][sender.tag]
  }
  @objc func closeWindow() { window?.performClose(nil) }
}

/// 应用图标：一块深色玻璃上几道彩色地层，对应条带图的泳道。运行时画给 Dock，构建时导出成 icns。
enum AppIconArt {
  static func image(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      draw(in: rect); return true
    }
  }

  static func draw(in rect: CGRect) {
    let s = rect.width
    let inset = s * 0.1
    let tile = rect.insetBy(dx: inset, dy: inset)
    let radius = tile.width * 0.225
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = s * 0.025; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 1).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.17, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.06, green: 0.06, blue: 0.09, alpha: 1)])!
      .draw(in: tile, angle: -90)

    // 地层：每道是一条泳道里的几段活动。
    let bands: [(UInt32, [(CGFloat, CGFloat)])] = [
      (0x8E95FF, [(0.08, 0.34), (0.40, 0.62), (0.70, 0.92)]),
      (0x3FCAD6, [(0.16, 0.30), (0.48, 0.80)]),
      (0xEE9170, [(0.06, 0.20), (0.26, 0.58), (0.66, 0.74)]),
      (0x52CC8C, [(0.34, 0.44), (0.56, 0.88)]),
      (0xF074C9, [(0.12, 0.46), (0.78, 0.94)]),
    ]
    let left = tile.minX + tile.width * 0.14, width = tile.width * 0.72
    let barH = tile.height * 0.066, gap = tile.height * 0.06
    var y = tile.midY + (CGFloat(bands.count) * barH + CGFloat(bands.count - 1) * gap) / 2 - barH
    for (hex, segs) in bands {
      let c = NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
      NSColor.white.withAlphaComponent(0.06).setFill()
      NSBezierPath(roundedRect: CGRect(x: left, y: y, width: width, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
      for (a, b) in segs {
        let r = CGRect(x: left + width * a, y: y, width: width * (b - a), height: barH)
        NSGradient(colors: [c.withAlphaComponent(0.75), c])!.draw(in: NSBezierPath(roundedRect: r, xRadius: barH / 2, yRadius: barH / 2), angle: 0)
      }
      y -= barH + gap
    }
    // "此刻"指针
    let needleX = left + width * 0.64
    NSColor(srgbRed: 1, green: 0.39, blue: 0.41, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: needleX - s * 0.006, y: tile.minY + tile.height * 0.17, width: s * 0.012, height: tile.height * 0.66), xRadius: s * 0.006, yRadius: s * 0.006).fill()
    NSBezierPath(ovalIn: CGRect(x: needleX - s * 0.022, y: tile.minY + tile.height * 0.83 - s * 0.022, width: s * 0.044, height: s * 0.044)).fill()

    // 顶部高光
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
      .draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.12).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.002, dy: s * 0.002), xRadius: radius, yRadius: radius)
    rim.lineWidth = s * 0.004; rim.stroke()
  }

  /// 构建脚本调用：把各尺寸 PNG 写进 iconset 目录，再由 iconutil 打包。
  static func writeIconset(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let px = base * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
      }
    }
  }
}
