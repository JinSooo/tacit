import AppKit
import SwiftUI
import struct CollectorCore.UpdateManifest
import enum CollectorCore.L10n

/// 每天看一次官网的 latest.json，有新的 Mac 版就在时间线顶部提一行。
/// 请求不带 Cookie、不带本机信息，失败就安静地等下一次。
@MainActor @Observable final class UpdateNotice {
  private static let skippedKey = "update.skippedVersion"
  private static let checkedKey = "update.checkedAt"
  /// 官网上比当前新的版本；时间线那一行还要再排除用户跳过的版本。
  private(set) var latest: UpdateManifest?
  private(set) var available: UpdateManifest?
  /// 设置里手动检查的结果：nil 是还没手动查过。
  private(set) var manual: ManualCheck?
  enum ManualCheck: Equatable { case checking, upToDate, failed }
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
    guard let page = (available ?? latest)?.page else { return }
    NSWorkspace.shared.open(page)
  }

  /// 设置里的“检查更新”：不管离上次多久都立刻查，结果留在那一行里。
  func checkNow() {
    guard manual != .checking else { return }
    manual = .checking
    Task {
      let ok = await check()
      manual = !ok ? .failed : latest == nil ? .upToDate : nil
    }
  }

  /// 离开设置时清掉上次手动检查的结果，下次进来又能点“检查更新”；不然“已是最新”会一直留到应用重启。
  func clearManualResult() {
    if manual != .checking { manual = nil }
  }

  var canCheck: Bool { currentVersion != nil }

  var currentVersion: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  private func checkIfDue() {
    let last = UserDefaults.standard.double(forKey: Self.checkedKey)
    // 上次查到的新版本也记着，重开应用不用等一天才再出现。
    if let cached = UserDefaults.standard.data(forKey: Self.checkedKey + ".body") { apply(cached) }
    guard Date().timeIntervalSince1970 - last >= 24 * 3600 else { return }
    Task { await check() }
  }

  @discardableResult private func check() async -> Bool {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15
    configuration.httpAdditionalHeaders = ["User-Agent": "Tacit"]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    guard let (data, response) = try? await session.data(from: UpdateManifest.url),
          (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16 * 1024 else { return false }
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
    UserDefaults.standard.set(data, forKey: Self.checkedKey + ".body")
    apply(data)
    return true
  }

  private func apply(_ data: Data) {
    let newest = UpdateManifest.newer(than: currentVersion, in: data)
    let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
    let next = newest?.version == skipped ? nil : newest
    latest = newest
    if next != available { Motion.animate { self.available = next } }
  }
}

struct TimelineUpdateLine: View {
  let notice: UpdateNotice
  let update: UpdateManifest

  var body: some View {
    HStack(spacing: 8) {
      PhIcon("arrow-clockwise", size: 14)
      Text(L10n.updateAvailable(update.version))
      Spacer(minLength: 8)
      Button(L10n.skipThisVersion) { notice.skip() }.buttonStyle(.accentLink).foregroundStyle(Palette.muted).fixedSize()
      Button(L10n.download) { notice.download() }.buttonStyle(.accentLink).fixedSize()
    }
    .font(.system(size: TextSize.body))
    .foregroundStyle(Palette.accent)
    .padding(.vertical, 4)
  }
}

/// 设置“关于”里的版本行：版本号 + 检查更新，结果就写在这一行。
struct SettingsVersionRow: View {
  let notice: UpdateNotice

  var body: some View {
    SettingsRow("Tacit") {
      HStack(spacing: 12) {
        Text(L10n.Settings.appVersion(notice.currentVersion ?? L10n.Settings.developmentBuild)).foregroundStyle(Palette.muted)
        if notice.canCheck { trailing }
      }
    }
    .onDisappear { notice.clearManualResult() }
  }

  @ViewBuilder private var trailing: some View {
    if let latest = notice.latest {
      Button(L10n.Settings.updateTo(latest.version)) { notice.download() }.buttonStyle(.accentLink).fixedSize()
    } else {
      switch notice.manual {
      case .checking: ProgressView().controlSize(.small)
      case .upToDate: Text(L10n.Settings.upToDate).foregroundStyle(Palette.muted)
      case .failed:
        Text(L10n.Settings.updateCheckFailed).foregroundStyle(Palette.muted)
        Button(L10n.Settings.checkForUpdates) { notice.checkNow() }.buttonStyle(.accentLink).fixedSize()
      case nil: Button(L10n.Settings.checkForUpdates) { notice.checkNow() }.buttonStyle(.accentLink).fixedSize()
      }
    }
  }
}
