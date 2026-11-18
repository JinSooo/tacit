import AppKit
import SwiftUI
import CollectorCore

/// 主窗口。采集端平时只在菜单栏；打开窗口时临时出现在 Dock 和 ⌘Tab 里，关掉窗口后退回菜单栏。
@MainActor final class ViewerWindow: NSObject, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
  let store: ViewerStore
  private var window: NSWindow?

  init(store: ViewerStore) {
    self.store = store
    super.init()
    // "开始听写"的标题每次校验都会被 AppKit 按"开始/停止"重写成英文，改不住；不在编辑菜单里列出，
    // 听写仍可用系统快捷键启动。
    UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true])
  }

  func show(_ entry: ViewerEntry? = nil) {
    switch entry {
    case .timeline: store.showReview()
    case .settings: store.showSettings()
    case .pending: store.showPending()
    case .record(let id, let date):
      store.showDayRecords(date, record: id)
    case nil:
      if window?.isVisible != true { store.showReview() }
    }
    if window == nil { window = makeWindow() }
    NSApp.setActivationPolicy(.regular)
    NSApp.applicationIconImage = AppIconArt.image(size: 512)
    NSApp.mainMenu = makeMenu()
    DispatchQueue.main.async { if let m = NSApp.mainMenu { Self.localizeSystemItems(m) } }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  private func makeWindow() -> NSWindow {
    let hosting = NSHostingController(rootView: RootView().environment(store))
    hosting.sceneBridgingOptions = [.toolbars, .title]
    let w = NSWindow(contentViewController: hosting)
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    w.toolbarStyle = .unified
    // 首次打开就可能落在无标题页面。后续页面标题由 SwiftUI 桥接到窗口。
    w.title = ""
    w.contentMinSize = NSSize(width: 1080, height: 640)
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
      m.delegate = self
      items.forEach(m.addItem)
      let host = NSMenuItem(title: title, action: nil, keyEquivalent: ""); host.submenu = m
      main.addItem(host)
    }
    func item(_ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = target; i.tag = tag; return i
    }
    // ⌘Q 只关窗口：采集端要一直在后台记录，真正退出走菜单栏图标里的"退出"。
    submenu("Tacit", [
      item("关于 Tacit", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
      .separator(),
      item("设置…", #selector(go(_:)), ",", target: self, tag: 3),
      .separator(),
      item("隐藏 Tacit", #selector(NSApplication.hide(_:)), "h", target: NSApp),
      .separator(),
      item("关闭窗口（继续在后台记录）", #selector(closeWindow), "q", target: self),
    ])
    submenu("编辑", [
      // 不走系统的 undo:/redo:：AppKit 会按应用语言把标题改回 "Undo"/"Redo"（本应用不声明 zh-Hans，见 build.sh）。
      item("撤销", #selector(undoInFocus(_:)), "z", target: self), item("重做", #selector(redoInFocus(_:)), "z", [.command, .shift], target: self), .separator(),
      item("剪切", #selector(NSText.cut(_:)), "x"), item("复制", #selector(NSText.copy(_:)), "c"),
      item("粘贴", #selector(NSText.paste(_:)), "v"), item("全选", #selector(NSText.selectAll(_:)), "a"),
    ])
    submenu("前往", [
      item("时间线", #selector(go(_:)), "1", target: self, tag: 0),
      item("搜索", #selector(go(_:)), "2", target: self, tag: 1),
    ])
    submenu("窗口", [
      item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"), item("缩放", #selector(NSWindow.performZoom(_:))),
      item("关闭", #selector(NSWindow.performClose(_:)), "w"),
    ])
    return main
  }

  @objc func go(_ sender: NSMenuItem) {
    switch sender.tag {
    case 0: store.showReview()
    case 1: store.section = .search
    case 3: store.showSettings()
    default: break
    }
  }
  @objc func closeWindow() { window?.performClose(nil) }

  /// AppKit 自己往编辑、窗口菜单里插的项按应用语言（英文）命名，打开菜单前改成中文。
  static let systemItemTitles: [String: String] = [
    "startDictation:": "开始听写…", "orderFrontCharacterPalette:": "表情与符号", "closeAll:": "全部关闭",
    "_handleInsertFromContactsCommand:": "联系人…", "_handleInsertFromPasswordsCommand:": "密码…",
    "_handleInsertFromCreditCardsCommand:": "信用卡…",
  ]
  nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
    MainActor.assumeIsolated { Self.localizeSystemItems(menu) }
  }
  static func localizeSystemItems(_ menu: NSMenu) {
    for item in menu.items {
      // 有的项（听写）动作名和标识不同，两个都查。
      let keys = [item.action.map(NSStringFromSelector), item.identifier?.rawValue].compactMap { $0 }
      if let title = keys.lazy.compactMap({ systemItemTitles[$0] }).first { item.title = title }
      if item.identifier?.rawValue == "_NSMenuItemAutoFillIdentifier" { item.title = "自动填充" }
      if let sub = item.submenu, sub.delegate == nil { localizeSystemItems(sub) }
    }
  }

  /// 撤销、重做交给当前焦点所在控件的撤销管理器（包括补写、修正这些弹出窗口里的输入框）。
  private var focusedUndoManager: UndoManager? { NSApp.keyWindow?.firstResponder?.undoManager }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(undoInFocus(_:)): return focusedUndoManager?.canUndo ?? false
    case #selector(redoInFocus(_:)): return focusedUndoManager?.canRedo ?? false
    default: return true
    }
  }
  @objc func undoInFocus(_ sender: NSMenuItem) { focusedUndoManager?.undo() }
  @objc func redoInFocus(_ sender: NSMenuItem) { focusedUndoManager?.redo() }
}
