import Foundation
import Testing
@testable import CollectorCore

@Test(arguments: AppLanguage.allCases)
func responseAndNetworkErrorsUseLocalizedMessages(_ language: AppLanguage) {
  AppLanguage.$scopedLanguage.withValue(language) {
    let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "EXAMPLE_INTERNAL_DUMP"))
    let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                          userInfo: [NSLocalizedDescriptionKey: "EXAMPLE_SYSTEM_DETAIL"])
    let cases: [(Error, String)] = [
      (decoding, L10n.unreadableResponse),
      (URLError(.timedOut), L10n.serviceTimedOut),
      (URLError(.cannotConnectToHost), L10n.cantReachBackgroundService),
      (offline, L10n.serviceOffline),
      (DeviceClientError.transportError("EXAMPLE_SYSTEM_DETAIL", code: .timedOut), L10n.serviceTimedOut),
      (HubError(status: 0, kind: .deviceLink), L10n.deviceConnectionUnavailable),
      (HubError(status: 0, kind: .badResponse), L10n.unreadableResponse),
    ]
    for (error, message) in cases {
      #expect(UserFacingError.message(for: error, fallback: "fallback") == message)
    }
  }
}

@Test(arguments: AppLanguage.allCases)
func hubErrorsKeepStatusMeaningWithoutShowingStatusCodes(_ language: AppLanguage) {
  AppLanguage.$scopedLanguage.withValue(language) {
    let cases: [(Int, String)] = [
      (401, L10n.serviceAccessExpired), (403, L10n.serviceAccessExpired),
      (404, L10n.serviceFeatureUnavailable), (409, L10n.serviceOperationInProgress),
      (413, L10n.responseTooLarge), (500, L10n.backgroundServiceFailed), (503, L10n.backgroundServiceFailed),
    ]
    for (status, message) in cases {
      let error = HubError(serviceMessage: "请求失败（\(status)）", status: status)
      #expect(UserFacingError.message(for: error, fallback: "fallback") == message)
    }
    #expect(UserFacingError.message(for: HubError(serviceMessage: "Internal error", status: 400), fallback: "fallback") == "fallback")
  }
}

@Test(arguments: AppLanguage.allCases)
func backendTextMustPassTheSameFilterInSettingsAndHubErrors(_ language: AppLanguage) {
  AppLanguage.$scopedLanguage.withValue(language) {
    let untrusted = [
      "需要有效的 bEaReR token", "请求失败 HTTP 500", "出错了 Exception: failure", "tier 必须是 minute、hour 或 day", "只接受 tier 和 config",
      "存储操作失败", "中枢返回了错误", "OCR 兜底", "读取 models.json 时记录了 Stack",
      "需要重新注入", "档位未配置", "提炼线程失败", "解析失败 (500)", "系统出现错误（401）",
      "操作失败\n详细信息", "The operation couldn't be completed.", String(repeating: "测", count: 121),
    ]
    for message in untrusted {
      #expect(L10n.Settings.serviceMessage(message, fallback: "fallback") == "fallback")
      #expect(UserFacingError.message(for: HubError(serviceMessage: message, status: 409), fallback: "fallback")
        == L10n.serviceOperationInProgress)
    }
    let known = "不能移除最后一台管理设备"
    let translated = language == .zh ? known : "Keep at least one device with management access."
    #expect(L10n.Settings.serviceMessage(known, fallback: "fallback") == translated)
    #expect(UserFacingError.message(for: HubError(serviceMessage: known, status: 409), fallback: "fallback") == translated)
    let unknown = "请稍后重新保存"
    #expect(L10n.Settings.serviceMessage(unknown, fallback: "fallback") == (language == .zh ? unknown : "fallback"))
    let key = "API key 格式不对：应为 8–1024 个英文字母、数字或符号，不能有空格、双引号或反斜杠。"
    #expect(L10n.Settings.serviceMessage(key, fallback: "fallback") == (language == .zh ? key :
      "Use 8–1,024 letters, numbers, or symbols for the API key. Omit spaces, double quotes, and backslashes."))
  }
}

@Test(arguments: AppLanguage.allCases)
func supportedServiceInstructionsRemainVisible(_ language: AppLanguage) {
  AppLanguage.$scopedLanguage.withValue(language) {
    let cases = [
      ("地址要是完整的 http 或 https 链接，不能带用户名、密码或问号后的参数。",
       "Enter a full HTTP or HTTPS URL without a username, password, or query parameters.", 400),
      ("模型列表只接受本机 HTTP(S) 地址", "Use a local HTTP or HTTPS address to list models.", 400),
      ("Git 地址需使用 https:// 或 ssh://", "Use an https:// or ssh:// Git URL.", 400),
      ("Git 地址需使用 HTTPS 或 SSH，不能包含密码或令牌",
       "Use an HTTPS or SSH Git URL without a password or access credential.", 400),
      ("目录中缺少有效的 plugin.json 清单", "The folder is missing a valid plugin.json manifest.", 400),
      ("上一次测试还没结束", "A test is already running.", 409),
    ]
    for (zh, en, status) in cases {
      let error = HubError(serviceMessage: zh, status: status)
      #expect(UserFacingError.message(for: error, fallback: L10n.Settings.connectionFailed) == (language == .zh ? zh : en))
    }
  }
}

@Test func preparationPermissionsAndDownloadFailuresFollowTheCurrentLanguage() {
  AppLanguage.$scopedLanguage.withValue(.en) {
    #expect(L10n.permission("完全磁盘访问") == "Full Disk Access")
  }
  for category in ["network", "checksum", "disk", "extract", "unknown"] {
    let stderr = "audio_models_error:\(category)"
    let zh = L10n.Settings.speechModelDownloadMessage(stderr: stderr, lang: .zh)
    let en = L10n.Settings.speechModelDownloadMessage(stderr: stderr, lang: .en)
    #expect(zh != en)
    AppLanguage.$scopedLanguage.withValue(.en) {
      #expect(L10n.Settings.recordingStatus(zh) == en)
    }
    AppLanguage.$scopedLanguage.withValue(.zh) {
      #expect(L10n.Settings.recordingStatus(en) == zh)
    }
  }
}

@Test(arguments: AppLanguage.allCases)
func loginStartupAndBackendSwitchErrorsKeepTheirRecoveryGuidance(_ language: AppLanguage) {
  AppLanguage.$scopedLanguage.withValue(language) {
    let cases: [(Error, String, String)] = [
      (LoginStartup.StartupError.notInstalled, "启动配置不完整，请重新安装应用后再试。",
       "Startup settings are incomplete. Reinstall Tacit and try again."),
      (LoginStartup.StartupError.duplicate, "发现重复的启动配置，未作更改。请重新安装应用后再试。",
       "Duplicate startup settings were found, so the change was skipped. Reinstall Tacit and try again."),
      (LoginStartup.StartupError.switching, "后台正在切换，登录启动暂时无法更改。",
       "Wait for the background service to finish switching before changing login startup."),
      (RemoteSwitchWriteGate.Paused(), "正在切换后台，新的写入暂缓。",
       "Saving is paused while the background service switches."),
    ]
    for (error, zh, en) in cases {
      #expect(UserFacingError.message(for: error, fallback: "fallback") == (language == .zh ? zh : en))
    }
  }
}
