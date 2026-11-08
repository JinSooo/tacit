import AppKit
import ApplicationServices

struct AXSnapshot {
  var window: String
  var url: String?
  var lines: [String]
  var frame: CGRect?
  var chars: Int
  var elements: Int
  var truncated: Bool
  var ms: Int
}

/// 读前台应用聚焦窗口的辅助功能树。
/// 实验 0-B 的约束：只读聚焦窗口；每次扫描有元素数和时间上限；跳过与窗口可见区域不相交的子树。
final class AXReader {
  var maxElements = 3000
  var budget: TimeInterval = 0.2
  private var manualEnabled = Set<pid_t>()

  private let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXHeading", "AXComboBox"]
  /// 只在这些容器上取 frame 判断是否可见；逐个叶子取 frame 太贵。
  private let containerRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXList", "AXOutline", "AXTable",
                                              "AXRow", "AXCell", "AXSplitGroup", "AXTabGroup", "AXLayoutArea"]

  struct Walk {
    var deadline: Date
    var elements = 0
    var truncated = false
    var lines: [String] = []
    var seen = Set<String>()
    var chars = 0
    var url: String?
  }

  func snapshot(pid: pid_t) -> AXSnapshot? {
    let started = Date()
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    if !manualEnabled.contains(pid) {
      // Electron 需要显式打开辅助功能树；每个进程只设一次，反复设置会让前台卡顿。
      AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
      manualEnabled.insert(pid)
    }
    guard let win = element(app, kAXFocusedWindowAttribute) else { return nil }
    let title = string(win, kAXTitleAttribute) ?? ""
    let frame = frameOf(win)
    var w = Walk(deadline: started.addingTimeInterval(budget))
    walk(win, visible: frame, depth: 0, &w)
    return AXSnapshot(window: title, url: w.url, lines: w.lines, frame: frame, chars: w.chars,
                      elements: w.elements, truncated: w.truncated, ms: Int(Date().timeIntervalSince(started) * 1000))
  }

  func forget(pid: pid_t) { manualEnabled.remove(pid) }

  private func walk(_ el: AXUIElement, visible: CGRect?, depth: Int, _ w: inout Walk) {
    if depth > 40 || w.elements >= maxElements || Date() > w.deadline { w.truncated = true; return }
    w.elements += 1
    let role = string(el, kAXRoleAttribute) ?? ""
    if role == "AXSecureTextField" { return }
    if depth > 0, containerRoles.contains(role), let vis = visible, let f = frameOf(el),
       f.width > 0, f.height > 0, !f.intersects(vis) { return }

    if textRoles.contains(role), let s = string(el, kAXValueAttribute) {
      add(s, &w)
    } else if role == "AXTextArea" {
      add(visibleText(el), &w)
    } else if role == "AXWebArea", w.url == nil, let u = url(el) {
      w.url = u
    }

    // 表格和大纲优先只取可见行（Mail 不设限时会把整个邮件列表读出来）。
    let kids = children(el, role == "AXTable" || role == "AXOutline" ? "AXVisibleRows" : nil)
    for k in kids { walk(k, visible: visible, depth: depth + 1, &w) }
  }

  private func add(_ text: String, _ w: inout Walk) {
    for line in text.split(whereSeparator: \.isNewline) {
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.isEmpty || w.seen.contains(t) { continue }
      w.seen.insert(t); w.lines.append(t); w.chars += t.count
    }
  }

  /// 终端这类文本区只取可见范围，不读整个回滚缓冲。
  private func visibleText(_ el: AXUIElement) -> String {
    var range: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXVisibleCharacterRangeAttribute as CFString, &range) == .success, let range {
      var out: CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, range, &out) == .success,
         let s = out as? String { return s }
    }
    return String((string(el, kAXValueAttribute) ?? "").suffix(5000))
  }

  // MARK: AX helpers

  private func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
  }
  private func string(_ el: AXUIElement, _ name: String) -> String? { raw(el, name) as? String }
  private func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    guard let v = raw(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
  }
  private func children(_ el: AXUIElement, _ preferred: String?) -> [AXUIElement] {
    if let preferred, let arr = raw(el, preferred) as? [AXUIElement], !arr.isEmpty { return arr }
    return raw(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }
  private func url(_ el: AXUIElement) -> String? {
    guard let v = raw(el, "AXURL") else { return nil }
    if let u = v as? URL { return u.absoluteString }
    return v as? String
  }
  private func frameOf(_ el: AXUIElement) -> CGRect? {
    guard let p = raw(el, kAXPositionAttribute), let s = raw(el, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
  }
}
