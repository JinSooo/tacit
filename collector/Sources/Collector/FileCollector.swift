import Foundation
import CoreServices
import CollectorCore

/// FSEvents 只提供路径与标志；读取文件属性和下载来源，不打开文件正文。
/// 生命周期、回调、缓冲和状态均在主队列上串行执行。
final class FileCollector {
  private let device: String
  private let send: ([Record]) -> Void
  private let isPaused: () -> Bool
  private let home = FileManager.default.homeDirectoryForCurrentUser.path
  private var stream: FSEventStreamRef?
  private var buffer = FileAppearanceBuffer()
  private(set) var last: Date?
  private(set) var unavailable = false

  init(device: String, isPaused: @escaping () -> Bool, send: @escaping ([Record]) -> Void) {
    self.device = device; self.isPaused = isPaused; self.send = send
  }

  func start() {
    guard stream == nil, !isPaused() else { return }
    let paths = FileSourcePolicy.directories.map { home + "/" + $0 }
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
      guard let info else { return }
      let owner = Unmanaged<FileCollector>.fromOpaque(info).takeUnretainedValue()
      let paths = unsafeBitCast(rawPaths, to: NSArray.self)
      for index in 0..<count {
        if let path = paths[index] as? String { owner.receive(path: path, flags: flags[index]) }
      }
    }
    guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else {
      unavailable = true; return
    }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, .main)
    unavailable = !FSEventStreamStart(stream)
    if unavailable { stop() }
  }

  func stop() {
    if let stream {
      FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
      self.stream = nil
    }
    buffer.discardPending()
  }

  func flush(force: Bool = false) {
    guard !isPaused() else { buffer.discardPending(); return }
    let records = buffer.drain(now: Date(), device: device, force: force)
    if !records.isEmpty { last = Date(); send(records) }
  }

  private func receive(path: String, flags: FSEventStreamEventFlags) {
    guard !isPaused() else { return }
    // 丢失事件时不回扫用户目录，避免把旧文件错当作新文件。
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
      unavailable = true; return
    }
    let created = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
    let moved = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
    let removed = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
    guard FileSourcePolicy.acceptsChange(created: created, moved: moved, removed: removed) else { return }
    if moved, flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
      captureMovedDirectory(path: path)
      return
    }
    capture(path: path)
  }

  private func captureMovedDirectory(path: String) {
    guard FileSourcePolicy.shouldDescend(path: path, home: home),
          FileSourcePolicy.shouldDescend(path: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, home: home),
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeDirectory,
          let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
    // 只枚举本次移入的子树；不跟随符号链接，也不扫描黑名单目录。
    for case let url as URL in entries {
      guard !isPaused() else { return }
      guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
      if values.isSymbolicLink == true { entries.skipDescendants(); continue }
      if values.isDirectory == true {
        if !FileSourcePolicy.shouldDescend(path: url.path, home: home) { entries.skipDescendants() }
      } else { capture(path: url.path) }
    }
  }

  private func capture(path: String) {
    guard FileSourcePolicy.directory(path: path, home: home, isRegularFile: true) != nil,
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let directory = FileSourcePolicy.directory(path: path, home: home,
            isRegularFile: attributes[.type] as? FileAttributeType == .typeRegular),
          // 同样过滤链接目标，防止目录链接绕过黑名单或访问范围。
          FileSourcePolicy.directory(path: URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
            home: home, isRegularFile: true) != nil,
          let inode = attributes[.systemFileNumber] as? NSNumber,
          let created = attributes[.creationDate] as? Date,
          let size = attributes[.size] as? NSNumber else { return }
    var fromURL: String?
    if directory == "Downloads", let item = MDItemCreate(nil, path as CFString),
       let urls = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] { fromURL = urls.first }
    flush()
    buffer.append(FileAppearance(path: path, inode: inode.uint64Value, created: created, observed: Date(),
                                 size: size.int64Value, directory: directory, fromURL: fromURL))
  }
}
