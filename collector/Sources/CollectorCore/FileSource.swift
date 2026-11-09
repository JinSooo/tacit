import Foundation
import CryptoKit

public struct FileAppearance {
  public let path: String
  public let inode: UInt64
  public let created: Date
  public let observed: Date
  public let size: Int64
  public let directory: String
  public let fromURL: String?

  public init(path: String, inode: UInt64, created: Date, observed: Date, size: Int64,
              directory: String, fromURL: String? = nil) {
    self.path = path; self.inode = inode; self.created = created; self.observed = observed
    self.size = size; self.directory = directory; self.fromURL = fromURL
  }

  public var sourceRef: String {
    FileSourcePolicy.hash("\(path)|\(inode)|\(created.timeIntervalSince1970)")
  }

  public func record(device: String) -> Record {
    let url = URL(fileURLWithPath: path)
    var extra: [String: ContextValue] = ["dir": .string(directory), "ext": .string(url.pathExtension.lowercased()),
                                        "size": .integer(size)]
    if let fromURL, let clean = FileSourcePolicy.cleanURL(fromURL) { extra["from_url"] = .string(clean) }
    return Record(device: device, source: "mac.file", kind: "event", start: observed,
                  context: RecordContext(extra: extra),
                  title: "\(directory == "Downloads" ? "下载" : "新文件") · \(url.lastPathComponent)",
                  body: path, capture: Capture(method: "file"), sourceRef: sourceRef)
  }
}

public enum FileSourcePolicy {
  public static let directories = ["Downloads", "Desktop", "Documents"]
  public static func acceptsChange(created: Bool, moved: Bool, removed: Bool) -> Bool {
    (created || moved) && !removed
  }
  private static let temporaryExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "temp"]
  // bundle ID 之外，过滤这些应用常用的展示名目录。
  private static let blockedNames: Set<String> = ["keychain access", "passwords", "钥匙串访问", "密码",
    "proton pass", "1password", "bitwarden", "lastpass", "dashlane"]

  public static func directory(path: String, home: String, isRegularFile: Bool) -> String? {
    guard isRegularFile else { return nil }
    return classify(path: path, home: home, isDirectory: false)
  }

  public static func shouldDescend(path: String, home: String) -> Bool {
    classify(path: path, home: home, isDirectory: true) != nil
  }

  private static func classify(path: String, home: String, isDirectory: Bool) -> String? {
    let path = URL(fileURLWithPath: path).standardized.path
    let home = URL(fileURLWithPath: home).standardized.path
    guard let root = directories.first(where: {
      path.hasPrefix(home + "/" + $0 + "/") || (isDirectory && path == home + "/" + $0)
    }) else { return nil }
    let components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
    guard !components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" || $0 == ".build" }) else { return nil }
    guard !components.contains(where: { temporaryExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) else { return nil }
    for component in isDirectory ? components : Array(components.dropLast()) {
      let name = component.lowercased()
      if blockedNames.contains(name) || blockedNames.contains((name as NSString).deletingPathExtension) { return nil }
      if CapturePolicy.blockedBundles.contains(where: { name == $0.lowercased() || name.hasPrefix($0.lowercased() + ".") }) { return nil }
    }
    return root
  }

  public static func cleanURL(_ value: String) -> String? {
    guard var url = URLComponents(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty else { return nil }
    url.query = nil; url.fragment = nil; url.user = nil; url.password = nil
    return url.string
  }

  static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// 每个实际父目录一个 60 秒窗口；先缓冲，才能在超限时只产出一条汇总。
public struct FileAppearanceBuffer {
  private struct Window {
    var start: Date
    var count = 0
    var first: [FileAppearance] = []
    var digest = SHA256()
  }
  private var windows: [String: Window] = [:]
  private var seen: Set<String> = []

  public init() {}

  public mutating func append(_ file: FileAppearance) {
    guard seen.insert(file.sourceRef).inserted else { return }
    let parent = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
    var window = windows[parent] ?? Window(start: file.observed)
    window.count += 1
    if window.first.count < 20 { window.first.append(file) }
    window.digest.update(data: Data(file.sourceRef.utf8))
    windows[parent] = window
  }

  public mutating func drain(now: Date, device: String, force: Bool = false) -> [Record] {
    var records: [Record] = []
    for key in windows.keys.sorted() {
      guard let w = windows[key], force || now.timeIntervalSince(w.start) >= 60 else { continue }
      if w.count <= 20 { records += w.first.map { $0.record(device: device) } }
      else {
        let ref = w.digest.finalize().map { String(format: "%02x", $0) }.joined()
        records.append(Record(device: device, source: "mac.file", kind: "event", start: w.start,
          context: RecordContext(extra: ["dir": .string(w.first[0].directory)]),
          title: "新文件 · \(w.count) 个（\(w.first[0].directory)）",
          body: w.first.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: "\n"),
          capture: Capture(method: "file"), sourceRef: ref))
      }
      windows.removeValue(forKey: key)
    }
    return records
  }

  public mutating func discardPending() { windows.removeAll() }
}
