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
      "需要有效的 bEaReR token", "读取JSON失败", "tier 必须是 minute、hour 或 day", "只接受 tier 和 config",
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
