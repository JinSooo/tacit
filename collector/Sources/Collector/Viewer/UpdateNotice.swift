import AppKit
import SwiftUI
import struct CollectorCore.UpdateManifest

/// 每天看一次官网的 latest.json，有新的 Mac 版就在时间线顶部提一行。
/// 请求不带 Cookie、不带本机信息，失败就安静地等下一次。
@MainActor @Observable final class UpdateNotice {
  private static let skippedKey = "update.skippedVersion"
  private static let checkedKey = "update.checkedAt"
  private(set) var available: UpdateManifest?
  @ObservationIgnored private var timer: Timer?

  func start() {
    guard timer == nil, currentVersion != nil else { return }
    // 启动后稍等，免得和后台准备抢网络；之后每小时看一眼是否满 24 小时。
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
    timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkIfDue() }
    }
  }

  func skip() {
    guard let available else { return }
    UserDefaults.standard.set(available.version, forKey: Self.skippedKey)
    Motion.animate { self.available = nil }
  }

  func download() {
    guard let available else { return }
    NSWorkspace.shared.open(available.page)
  }

  private var currentVersion: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  private func checkIfDue() {
    let last = UserDefaults.standard.double(forKey: Self.checkedKey)
    // 上次查到的新版本也记着，重开应用不用等一天才再出现。
    if let cached = UserDefaults.standard.data(forKey: Self.checkedKey + ".body") { apply(cached) }
    guard Date().timeIntervalSince1970 - last >= 24 * 3600 else { return }
    Task { await check() }
  }

  private func check() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15
    configuration.httpAdditionalHeaders = ["User-Agent": "Tacit"]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    guard let (data, response) = try? await session.data(from: UpdateManifest.url),
          (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16 * 1024 else { return }
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
    UserDefaults.standard.set(data, forKey: Self.checkedKey + ".body")
    apply(data)
  }

  private func apply(_ data: Data) {
    let latest = UpdateManifest.newer(than: currentVersion, in: data)
    let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
    let next = latest?.version == skipped ? nil : latest
    if next != available { Motion.animate { self.available = next } }
  }
}

struct TimelineUpdateLine: View {
  let notice: UpdateNotice
  let update: UpdateManifest

  var body: some View {
    HStack(spacing: 8) {
      PhIcon("arrow-clockwise", size: 14)
      Text("Tacit \(update.version) 可以更新了")
      Spacer(minLength: 8)
      Button("跳过这个版本") { notice.skip() }.buttonStyle(.accentLink).foregroundStyle(Palette.muted).fixedSize()
      Button("下载") { notice.download() }.buttonStyle(.accentLink).fixedSize()
    }
    .font(.system(size: TextSize.body))
    .foregroundStyle(Palette.accent)
    .padding(.vertical, 4)
  }
}
