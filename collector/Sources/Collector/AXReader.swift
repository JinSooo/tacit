import CollectorCore
import AppKit
import ApplicationServices

struct AXSnapshot {
  var window: String
  var url: String?
  var lines: [String]
  var editable: [[Int]: [String]]
  var editableFrames: [CGRect]
  var frame: CGRect?
  var chars: Int
  var elements: Int
  var calls: Int
  var truncated: Bool
  var ms: Int
}

/// 读前台应用聚焦窗口的辅助功能树。
/// 实验 0-B 的约束：只读聚焦窗口；每次扫描有元素数和时间上限；跳过与窗口可见区域不相交的子树。
///
/// 遍历方式：每个元素一次 IPC 批量取角色、子节点、位置、尺寸（逐个属性取要 3–5 次，实测慢一到三倍）；
/// 所有元素都做可见性剪枝；同一层子节点按面积从大到小访问，让主内容区先于侧栏、工具栏用掉预算；
/// 输出时再按文档顺序（子节点下标路径）排序，正文顺序不受访问顺序影响。
/// 深度上限 60：Electron 应用（如 Claude 桌面版）的树超过 40 层。
final class AXReader {
  var maxElements = 3000
  var budget: TimeInterval = 0.2
  var maxDepth = 60
  private var manualEnabled = Set<pid_t>()

  private let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXHeading", "AXComboBox"]
  private let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
  private let batchAttributes = [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray

  struct Walk {
    var deadline: Date
    var elements = 0
    var calls = 0
    var truncated = false
    var pieces: [(path: [Int], text: String)] = []
    var editable: [[Int]: [String]] = [:]
    var editableFrames: [CGRect] = []
    var url: String?
  }

  struct Node { var el: AXUIElement; var role: String; var kids: [AXUIElement]; var frame: CGRect? }

  /// Electron 需要显式打开辅助功能树；每个进程只设一次，反复设置会让前台卡顿。
  func prepare(pid: pid_t) {
    guard !manualEnabled.contains(pid) else { return }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    manualEnabled.insert(pid)
  }

  func snapshot(pid: pid_t, includeText: Bool = true) -> AXSnapshot? {
    let started = Date()
    prepare(pid: pid)
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    guard let win = element(app, kAXFocusedWindowAttribute) else { return nil }
    let title = string(win, kAXTitleAttribute) ?? ""
    if !includeText || CapturePolicy.shouldSkip(bundleID: "", window: title) {
      return AXSnapshot(window: title, url: nil, lines: [], editable: [:], editableFrames: [], frame: nil,
                        chars: 0, elements: 0, calls: 2, truncated: false, ms: Int(Date().timeIntervalSince(started) * 1000))
    }
    let frame = frameOf(win)
    var w = Walk(deadline: started.addingTimeInterval(budget))
    w.calls = 4
    if let root = info(win, &w) { visitFast(root, visible: frame, depth: 0, path: [], &w) }
    // 按文档顺序输出并去重。
    var seen = Set<String>(), lines: [String] = [], chars = 0
    for p in w.pieces.sorted(by: { $0.path.lexicographicallyPrecedes($1.path) }) {
      for line in p.text.split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || seen.contains(t) { continue }
        seen.insert(t); lines.append(t); chars += t.count
      }
    }
    for line in w.editable.values.joined() where seen.insert(line).inserted { chars += line.count }
    return AXSnapshot(window: title, url: w.url, lines: lines, editable: w.editable, editableFrames: w.editableFrames,
                      frame: frame, chars: chars, elements: w.elements,
                      calls: w.calls, truncated: w.truncated, ms: Int(Date().timeIntervalSince(started) * 1000))
  }

  func forget(pid: pid_t) { manualEnabled.remove(pid) }

  private func overBudget(_ w: inout Walk) -> Bool {
    if w.elements >= maxElements || Date() > w.deadline { w.truncated = true; return true }
    return false
  }

  // MARK: 遍历

  private func info(_ el: AXUIElement, _ w: inout Walk) -> Node? {
    w.calls += 1; w.elements += 1
    var out: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(el, batchAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
          let vals = out as? [AnyObject], vals.count == 4 else { return nil }
    return Node(el: el, role: vals[0] as? String ?? "", kids: vals[1] as? [AXUIElement] ?? [],
                frame: rect(vals[2], vals[3]))
  }

  private func visitFast(_ n: Node, visible: CGRect?, depth: Int, path: [Int], _ w: inout Walk) {
    if n.role == "AXSecureTextField" { return }
    if editableRoles.contains(n.role), collectEditable(n, path: path, &w) { return }
    collectText(n.el, role: n.role, path: path, &w)
    if depth >= maxDepth { w.truncated = true; return }

    var kids = n.kids
    // 表格和大纲只取可见行（Mail 不设限时会把整个邮件列表读出来）。
    if n.role == "AXTable" || n.role == "AXOutline" {
      w.calls += 1
      if let rows = raw(n.el, "AXVisibleRows") as? [AXUIElement], !rows.isEmpty { kids = rows }
    }
    var nodes: [(index: Int, node: Node)] = []
    for (i, k) in kids.enumerated() {
      if overBudget(&w) { break }
      guard let c = info(k, &w) else { continue }
      if let vis = visible, let f = c.frame, f.width > 0, f.height > 0, !f.intersects(vis) { continue }
      nodes.append((i, c))
    }
    let ordered = nodes.sorted { a, b in
      let x = area(a.node.frame), y = area(b.node.frame)
      return x != y ? x > y : a.index < b.index
    }
    for (i, c) in ordered {
      if overBudget(&w) { return }
      visitFast(c, visible: visible, depth: depth + 1, path: path + [i], &w)
    }
  }

  private func area(_ f: CGRect?) -> CGFloat { guard let f else { return 0 }; return f.width * f.height }

  // MARK: 文本

  private func collectEditable(_ n: Node, path: [Int], _ w: inout Walk) -> Bool {
    var writable: DarwinBoolean = false
    w.calls += 1
    guard AXUIElementIsAttributeSettable(n.el, kAXValueAttribute as CFString, &writable) == .success,
          writable.boolValue else { return false }
    let text: String?
    var position = path
    if n.role == "AXTextArea" {
      w.calls += 2
      let value = visibleText(n.el)
      text = value.text
      // 同一个可见范围上的改写互相替换，滚到不同位置可保留那一处的文字。
      if let offset = value.offset { position += [-1, offset] }
    } else {
      w.calls += 1
      text = string(n.el, kAXValueAttribute)
    }
    guard let text else { return false }
    w.editable[position] = Text.lines(Text.capturePrefix(text, limit: 5000))
    if let frame = n.frame, !frame.isEmpty { w.editableFrames.append(frame) }
    // 编辑器内容已经从它的值读取，子节点中的副本不能再次成为普通正文。
    return true
  }

  private func collectText(_ el: AXUIElement, role: String, path: [Int], _ w: inout Walk) {
    if textRoles.contains(role) {
      w.calls += 1
      if let s = string(el, kAXValueAttribute), !s.isEmpty { w.pieces.append((path, s)) }
    } else if role == "AXTextArea" {
      w.calls += 2
      if let s = visibleText(el).text, !s.isEmpty { w.pieces.append((path, s)) }
    } else if role == "AXWebArea", w.url == nil {
      w.calls += 1
      w.url = url(el)
    }
  }

  /// 终端这类文本区只取可见范围，不读整个回滚缓冲。
  private func visibleText(_ el: AXUIElement) -> (text: String?, offset: Int?) {
    var range: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXVisibleCharacterRangeAttribute as CFString, &range) == .success, let range {
      var out: CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, range, &out) == .success,
         let s = out as? String {
        var visible = CFRange()
        let offset = CFGetTypeID(range) == AXValueGetTypeID()
          && AXValueGetValue(range as! AXValue, .cfRange, &visible) ? visible.location : nil
        return (s, offset)
      }
    }
    return (string(el, kAXValueAttribute).map { Text.captureSuffix($0, limit: 5000) }, nil)
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
  private func url(_ el: AXUIElement) -> String? {
    guard let v = raw(el, "AXURL") else { return nil }
    if let u = v as? URL { return u.absoluteString }
    return v as? String
  }
  private func rect(_ p: AnyObject?, _ s: AnyObject?) -> CGRect? {
    guard let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    let pv = p as! AXValue, sv = s as! AXValue
    guard AXValueGetType(pv) == .cgPoint, AXValueGetType(sv) == .cgSize else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(pv, .cgPoint, &point)
    AXValueGetValue(sv, .cgSize, &size)
    return CGRect(origin: point, size: size)
  }
  private func frameOf(_ el: AXUIElement) -> CGRect? { rect(raw(el, kAXPositionAttribute), raw(el, kAXSizeAttribute)) }
}
