// 实验 0-A/B/C 探针：权限是否随重新构建保留、子进程是否继承、AX 能读到多少文字
// 只记录字数和角色统计，不记录任何界面文字内容
import AppKit
import ApplicationServices

let mode = CommandLine.arguments.dropFirst().first ?? "check"
let outDir = "/tmp/ra-probe"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func axString(_ el: AXUIElement, _ attr: String) -> String? {
  var v: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
  return v as? String
}

struct Stats { var elements = 0; var textChars = 0; var labelChars = 0; var truncated = false }
let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXCell"]

func walk(_ el: AXUIElement, _ depth: Int, _ s: inout Stats) {
  if depth > 60 { return }
  if s.elements >= 30000 { s.truncated = true; return }
  s.elements += 1
  let role = axString(el, kAXRoleAttribute) ?? "?"
  for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
    if let str = axString(el, attr), !str.isEmpty {
      if textRoles.contains(role) && attr == kAXValueAttribute { s.textChars += str.count } else { s.labelChars += str.count }
    }
  }
  var kids: CFTypeRef?
  if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
    for k in arr { walk(k, depth + 1, &s) }
  }
}

func scanApp(_ app: NSRunningApplication) -> [String: Any] {
  let ax = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(ax, 1.0)
  func pass() -> [String: Any] {
    var s = Stats(); let t0 = Date()
    var wins: CFTypeRef?
    var nwin = 0
    if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wins) == .success, let arr = wins as? [AXUIElement] {
      nwin = arr.count
      for w in arr { walk(w, 0, &s) }
    }
    return ["windows": nwin, "elements": s.elements, "textChars": s.textChars, "labelChars": s.labelChars,
            "truncated": s.truncated, "ms": Int(Date().timeIntervalSince(t0) * 1000)]
  }
  let before = pass()
  // Electron / Chromium 需要显式打开辅助功能树
  let setRes = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  var after: [String: Any]? = nil
  if setRes == .success { Thread.sleep(forTimeInterval: 1.5); after = pass() }
  return ["bundle": app.bundleIdentifier ?? "?", "name": app.localizedName ?? "?",
          "plain": before, "manualAX": setRes == .success ? "ok" : "unsupported(\(setRes.rawValue))",
          "afterManualAX": after ?? NSNull()]
}

func runChild() -> [String: Any] {
  var r: [String: Any] = [:]
  let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/probe-child")
  // 1) Swift 子进程：AX 是否可信
  let p = Process(); p.executableURL = exe
  let pipe = Pipe(); p.standardOutput = pipe
  do { try p.run(); p.waitUntilExit()
       r["swiftChild"] = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
         .trimmingCharacters(in: .whitespacesAndNewlines) ?? "" } catch { r["swiftChild"] = "error: \(error)" }
  // 2) 受保护位置：自己读 vs shell 子进程读（只看能否读到 1 字节 / 列出目录，不记内容）
  let home = NSHomeDirectory()
  let targets: [(String, String, Bool)] = [   // 名称, 路径, 是否目录
    ("safariHistory", "\(home)/Library/Safari/History.db", false),
    ("messagesDB", "\(home)/Library/Messages/chat.db", false),
    ("mailDir", "\(home)/Library/Mail", true),
    ("systemTCC", "/Library/Application Support/com.apple.TCC/TCC.db", false),
  ]
  for (name, path, isDir) in targets {
    let selfOK: Bool
    if isDir { selfOK = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil }
    else { selfOK = (FileHandle(forReadingAtPath: path)?.readData(ofLength: 1).count ?? 0) > 0 }
    let sh = Process(); sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    let cmd = isDir ? "ls \"$P\"" : "head -c 1 \"$P\""
    sh.arguments = ["-c", "\(cmd) >/dev/null 2>&1 && echo readable || echo denied"]
    sh.environment = ["P": path]
    let pp = Pipe(); sh.standardOutput = pp
    var shOut = "error"
    if (try? sh.run()) != nil { sh.waitUntilExit()
      shOut = String(data: pp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    r[name] = "self=\(selfOK ? "readable" : "denied") shell=\(shOut)"
  }
  return r
}

let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: (mode == "prompt")] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
var report: [String: Any] = ["build": BUILD, "mode": mode, "trusted": trusted,
                             "time": ISO8601DateFormatter().string(from: Date())]
if mode == "child" || mode == "coverage" { report["child"] = runChild() }
if mode == "coverage" && trusted {
  report["apps"] = NSWorkspace.shared.runningApplications
    .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
    .map(scanApp)
}
// front 模式：只读当前前台应用的聚焦窗口（贴近真实采集场景），先打开 Electron 辅助功能再读
if mode == "front" && trusted, let app = NSWorkspace.shared.frontmostApplication {
  let ax = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(ax, 1.0)
  let setRes = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  Thread.sleep(forTimeInterval: 1.5)
  var s = Stats(); let t0 = Date()
  var fw: CFTypeRef?
  let ok = AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &fw) == .success
  if ok, let w = fw { walk(w as! AXUIElement, 0, &s) }
  report["front"] = ["bundle": app.bundleIdentifier ?? "?", "name": app.localizedName ?? "?",
                     "focusedWindow": ok, "manualAX": setRes == .success ? "ok" : "unsupported",
                     "elements": s.elements, "textChars": s.textChars, "labelChars": s.labelChars,
                     "truncated": s.truncated, "ms": Int(Date().timeIntervalSince(t0) * 1000)]
}
let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
let tag = CommandLine.arguments.count > 2 ? "-\(CommandLine.arguments[2])" : ""
try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(mode)\(tag)-build\(BUILD).json"))
if mode == "prompt" { RunLoop.main.run(until: Date().addingTimeInterval(20)) }
