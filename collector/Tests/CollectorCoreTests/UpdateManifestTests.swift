import Foundation
import Testing
@testable import CollectorCore

private func manifest(_ version: String, _ url: String = "https://example.com/releases/tag/v1") -> Data {
  Data(#"{"mac":{"version":"\#(version)","url":"\#(url)"}}"#.utf8)
}

@Test func updateManifestOnlyOffersNewerHttpsReleases() {
  #expect(UpdateManifest.newer(than: "0.6.4", in: manifest("0.6.5"))?.version == "0.6.5")
  #expect(UpdateManifest.newer(than: "0.6.4", in: manifest("0.10.0"))?.version == "0.10.0")
  #expect(UpdateManifest.newer(than: "0.6", in: manifest("0.6.1")) != nil)
  for latest in ["0.6.4", "0.6.3", "0.6.4.0", "abc", ""] {
    #expect(UpdateManifest.newer(than: "0.6.4", in: manifest(latest)) == nil)
  }
  #expect(UpdateManifest.newer(than: "0.6.4", in: manifest("0.7.0", "http://example.com/x")) == nil)
  #expect(UpdateManifest.newer(than: nil, in: manifest("0.7.0")) == nil)
  #expect(UpdateManifest.newer(than: "0.6.4", in: Data("{}".utf8)) == nil)
}

/// 2026-11-25 虚拟机实测：没装 Claude Code 时默认模型只报“命令行调用失败”，说不出缺什么。
@Test func missingCliIsExplainedAndNeedsUser() {
  #expect(ModelErrorText.plain("cli_missing").contains("没找到 Claude Code"))
  #expect(ModelErrorText.needsUser("cli_missing"))
}

/// 2026-11-25 虚拟机实测：开机“重新打开窗口”恢复 Tacit 时也算访达启动，主窗口每次开机都弹出来。
@Test func launchWindowStaysQuietRightAfterLogin() {
  let login = Date(timeIntervalSince1970: 1_000_000)
  #expect(!LaunchWindowPolicy.opensWindow(source: .finder, loginAt: login, now: login.addingTimeInterval(20)))
  #expect(LaunchWindowPolicy.opensWindow(source: .finder, loginAt: login, now: login.addingTimeInterval(600)))
  #expect(LaunchWindowPolicy.opensWindow(source: .finder, loginAt: nil))
  #expect(!LaunchWindowPolicy.opensWindow(source: .launchd, loginAt: login, now: login.addingTimeInterval(600)))
  #expect(LoginSession.consoleLoginDate().map { $0 <= Date() } ?? true)
}
