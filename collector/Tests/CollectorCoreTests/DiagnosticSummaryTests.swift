@testable import CollectorCore
import Foundation
import Testing

private let diagnosticTime = "2026-11-19T14:00:00+09:00"

private func withDiagnosticDirectory(_ test: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory.appendingPathComponent("logs"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try test(directory)
}

private func summary(in directory: URL, reachable: Bool = false, status: Data? = nil) -> String {
  DiagnosticSummary.make(dataDir: directory, hubReachable: reachable, hubStatus: status,
                         version: "0.3.0", build: "abcd123",
                         macOSVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0),
                         architecture: "arm64", now: ViewerTime.parse(diagnosticTime)!,
                         timeZone: TimeZone(identifier: "Asia/Tokyo")!)
}

@Test(ChineseUITrait()) func startupDiagnosticPrefersSpecificFailureAndIgnoresCorruption() throws {
  try withDiagnosticDirectory { directory in
    let startup = directory.appendingPathComponent("hub-startup-error.json")
    let setup = directory.appendingPathComponent("setup-status.json")
    #expect(DiagnosticSummary.startupMessage(in: directory) == nil)
    try Data(#"{"at":"2026-11-19T14:00:00+09:00","version":"0.3.0","build":"abcd123","exit_code":17,"ok":false}"#.utf8).write(to: setup)
    #expect(DiagnosticSummary.startupMessage(in: directory) == L10n.Settings.setupFailure(.unknown))
    try Data(#"{"at":"2026-11-19T14:00:00+09:00","code":"port_in_use","message":"后台服务端口已被占用。"}"#.utf8).write(to: startup)
    #expect(DiagnosticSummary.startupMessage(in: directory) == L10n.Settings.setupFailure(.portInUse))
    let oldStatus = try Data(contentsOf: setup)
    try Data(#"{"at":"2026-11-19T14:00:01+09:00","version":"0.3.0","build":"abcd123","exit_code":1,"ok":false,"reason":"database"}"#.utf8).write(to: setup)
    #expect(DiagnosticSummary.startupMessage(in: directory) == L10n.Settings.setupFailure(.database))
    try oldStatus.write(to: setup)
    try Data("{".utf8).write(to: startup)
    #expect(DiagnosticSummary.startupMessage(in: directory) == L10n.Settings.setupFailure(.unknown))
    try FileManager.default.removeItem(at: startup)
    try Data(#"{"ok":false,"exit_code":"17"}"#.utf8).write(to: setup)
    #expect(DiagnosticSummary.startupMessage(in: directory) == nil)
  }
}

@Test(ChineseUITrait()) func diagnosticSummaryWorksOfflineWithoutSharingContentOrCredentials() throws {
  try withDiagnosticDirectory { directory in
    let token = "fake_access_token_0123456789"
    let privatePath = "/Users/example-person/ExampleProject"
    let privateBody = "这是一条合成的私人记录正文"
    try Data("""
      {"at":"\(diagnosticTime)","code":"db_open_failed","message":"读取 \(privatePath) 失败"}
      """.utf8).write(to: directory.appendingPathComponent("hub-startup-error.json"))
    try Data("""
      {"at":"\(diagnosticTime)","version":"0.3.0","build":"abcd123","exit_code":1,"ok":false,"token":"\(token)"}
      """.utf8).write(to: directory.appendingPathComponent("setup-status.json"))
    try Data("""
      {"time":"\(diagnosticTime)","axTrusted":true,"ocrGranted":false,"queue":12,"sent":45,"rejected":1,"dropped":2,
       "hubError":"hub 连不上：\(privatePath)","transcription":{"pending":3,"failed":1},"outboxBytes":2048,
       "outboxDropped":6,"outboxDegraded":true,"title":"\(privateBody)","token":"\(token)"}
      """.utf8).write(to: directory.appendingPathComponent("collector-status.json"))
    let log = directory.appendingPathComponent("logs/hub.log")
    let logText = """
      \(privateBody)
      {"at":"\(diagnosticTime)","component":"hub","code":"db_open_failed","count":4,"ok":false,"token":"\(token)","apiKey":123456,"privatePath":"\(privatePath)"}
      {"at":"\(diagnosticTime)","component":"hub","count":98765}
      """
    try Data(logText.utf8).write(to: log)
    try Data(privateBody.utf8).write(to: directory.appendingPathComponent("logs/ExampleProject.log"))

    let text = summary(in: directory)
    for expected in ["Tacit 0.3.0，构建 abcd123", "macOS 26.1.0，arm64", diagnosticTime, "Asia/Tokyo", "后台服务不可达",
                     "启动错误类别  db_open_failed", "结果  失败", "退出码  1", "辅助功能权限  已授权", "录屏权限  未授权",
                     "等待保存  12 条", "本次已保存  45 条", "拒收  1 条", "丢弃  2 条", "等待转写  3 段",
                     "转写失败  1 段", "待发送文件大小  2048 字节", "待发送记录丢弃  6 条", "待发送记录仅在内存中重试  是",
                     "保存错误类别  连不上后台服务", "hub.log  \(logText.utf8.count) 字节，修改于", "其他日志 1",
                     #""component":"hub""#, #""count":4"#, #""ok":false"#] {
      #expect(text.contains(expected))
    }
    for privateValue in [token, "example-person", "ExampleProject", privateBody, "123456", "98765", "hub 连不上："] {
      #expect(!text.contains(privateValue))
    }
  }
}

@Test(ChineseUITrait()) func diagnosticSummaryKeepsStatusCountsAndCategoriesOnly() throws {
  try withDiagnosticDirectory { directory in
    let status = Data("""
      {"hub":{"uptime_s":60},"database":{"bytes":4096,"file":"/Users/example-person/records.db"},
       "records":{"by_source":[{"source":"mac.audio","count":11,"last_received":"\(diagnosticTime)"},
                              {"source":"custom.SecretProject","count":5,"last_received":null}],
                  "by_device":[{"device":"ExampleDevice","count":16}]},
       "distill":{"heartbeat_at":"\(diagnosticTime)","last_round_at":"\(diagnosticTime)",
                  "last_error":{"error":"provider said fake_secret_ABC123"},
                  "cooldown":{"until":"2026-11-19T14:10:00+09:00","kind":"rate_limited:429"}},
       "llm_today":{"total":{"calls":33,"failed":2},"by_tier":[{"models":["private-model-name"]}]}}
      """.utf8)
    let text = summary(in: directory, reachable: true, status: status)
    for expected in ["后台服务可达", "运行时长  60 秒", "记录库大小  4096 字节", "mac.audio  11 条，最近入库 \(diagnosticTime)",
                     "其他来源 1  5 条，最近入库 未提供", "整理最近响应  \(diagnosticTime)", "最近一轮整理  \(diagnosticTime)",
                     "最近模型错误  未知错误", "暂停重试至 2026-11-19T14:10:00+09:00（请求太频繁（rate_limited:429））",
                     "今天模型调用  33 次", "今天模型调用失败  2 次"] {
      #expect(text.contains(expected))
    }
    for privateValue in ["example-person", "SecretProject", "ExampleDevice", "fake_secret_ABC123", "private-model-name"] {
      #expect(!text.contains(privateValue))
    }
    let cliFailure = Data(#"{"distill":{"last_error":{"error":"cli_not_logged_in:401","detail":"synthetic stderr line"}}}"#.utf8)
    let cliSummary = summary(in: directory, reachable: true, status: cliFailure)
    #expect(cliSummary.contains("最近模型错误  命令行工具未登录（cli_not_logged_in:401）"))
    #expect(!cliSummary.contains("synthetic stderr line"))
  }
}

@Test(ChineseUITrait()) func diagnosticSummaryAcceptsCollectorStatusWithoutOptionalCounters() throws {
  try withDiagnosticDirectory { directory in
    let status = directory.appendingPathComponent("collector-status.json")
    for (error, category) in [
      ("hub 连不上。", "连不上后台服务"),
      ("后台服务拒绝了记录（403）", "后台服务拒绝请求"),
      ("待发送记录无法安全保存，请检查磁盘空间和数据目录；暂时只在内存中重试。", "待发送记录保存失败"),
      ("有待发送记录无法安全保存或恢复。", "待发送记录保存失败"),
    ] {
      try JSONSerialization.data(withJSONObject: ["queue": 1, "hubError": error]).write(to: status)
      let text = summary(in: directory)
      #expect(text.contains("等待保存  1 条"))
      #expect(text.contains("保存错误类别  \(category)"))
      #expect(!text.contains(error))
      #expect(!text.contains("等待转写"))
      #expect(!text.contains("待发送文件大小"))
    }
  }
}

@Test func diagnosticSummaryKeepsOnlyThirtyNewestEventsAcrossLogs() throws {
  try withDiagnosticDirectory { directory in
    let logs = directory.appendingPathComponent("logs")
    for (offset, log) in ["hub", "distill", "collector"].enumerated() {
      let events = (offset * 12..<(offset + 1) * 12).map { index in
        let minute = String(format: "%02d", index)
        return #"{"at":"2026-11-19T14:\#(minute):00+09:00","code":"diagnostic","index":\#(index)}"#
      }
      try Data(events.joined(separator: "\r\n").utf8).write(to: logs.appendingPathComponent("\(log).log"))
    }
    let events = summary(in: directory).split(separator: "\n").filter { $0.hasPrefix("{") }
    #expect(events.count == 30)
    #expect(events.first?.contains(#""index":6}"#) == true)
    #expect(events.last?.contains(#""index":35}"#) == true)
  }
}

/// 2026-11-25：hub.log 里一种信箱错误每 5 秒一条，最近 30 条全被它占满；整理日志的错误没有 `code`，一直进不了诊断信息。
@Test func diagnosticSummaryFoldsRepeatedEventsAndKeepsDistillErrors() throws {
  try withDiagnosticDirectory { directory in
    let logs = directory.appendingPathComponent("logs")
    var hub = [#"{"at":"2026-11-19T13:00:00+09:00","location":"setup.agents","name":"Error","code":"EACCES"}"#]
    for second in 0..<50 {
      hub.append(#"{"at":"2026-11-19T14:00:\#(String(format: "%02d", second))+09:00","location":"relay.space","name":"TypeError","code":"ECONNRESET"}"#)
    }
    try Data(hub.joined(separator: "\n").utf8).write(to: logs.appendingPathComponent("hub.log"))
    try Data(#"{"at":"2026-11-19T13:30:00+09:00","step":"day","category":"schema_mismatch","count":1}"#.utf8)
      .write(to: logs.appendingPathComponent("distill.log"))
    let events = summary(in: directory).split(separator: "\n").filter { $0.hasPrefix("{") }
    #expect(events.count == 3)
    #expect(events.contains { $0.contains(#""component":"setup.agents""#) && $0.contains(#""code":"EACCES""#) })
    #expect(events.contains { $0.contains(#""component":"day""#) && $0.contains(#""code":"schema_mismatch""#) })
    #expect(events.last?.contains(#""times":50"#) == true)
    #expect(events.last?.contains("2026-11-19T14:00:49+09:00") == true)
  }
}

@Test func setupFailureCodesDecodeNewAndOldStatuses() throws {
  for code in ["bundle_incomplete", "database", "background_blocked", "service_unhealthy", "port_in_use", "unknown"] {
    let reason = try #require(SetupStatus.Reason(rawValue: code))
    let status = try JSONDecoder().decode(SetupStatus.self, from: Data(
      """
      {"at":"2026-11-19T14:00:00+09:00","version":"1","build":"2","exit_code":17,"ok":false,"reason":"\(code)"}
      """.utf8))
    #expect(status.reason == reason)
    #expect(SetupStatus.Reason.fromStandardError("earlier details\r\nsetup_error:\(code)\r\n") == reason)
    #expect(!L10n.Settings.setupFailure(reason, lang: .en).contains("exit code"))
    #expect(!L10n.Settings.setupFailure(reason, lang: .zh).contains(code))
  }
  let old = Data(#"{"at":"2026-11-19T14:00:00+09:00","version":"1","build":"2","exit_code":17,"ok":false}"#.utf8)
  #expect(try JSONDecoder().decode(SetupStatus.self, from: old).reason == .unknown)
  #expect(SetupStatus.Reason.fromStandardError("setup_error:port_in_use\nother log") == .unknown)
  #expect(SetupStatus.Reason.fromStandardError("setup_error:unrecognized") == .unknown)
  #expect(L10n.Settings.setupFailure(.backgroundBlocked, lang: .en).contains("Login Items & Extensions"))
  #expect(L10n.Settings.setupFailure(.portInUse, lang: .zh).contains("后台与连接"))
}

@Test func speechModelFailuresUseOnlyKnownLastLineAndCurrentLanguage() {
  let cases = [
    ("network", "连不上下载地址，检查网络或代理后会自动重试", "network or proxy"),
    ("checksum", "下载的文件不完整，会自动重新下载", "incomplete"),
    ("disk", "磁盘空间不够，清理后会自动重试", "disk space"),
    ("extract", "模型文件解压失败，会自动重试", "unpack"),
    ("unknown", "语音模型没能下载，稍后会自动重试", "retry shortly"),
  ]
  for (code, chinese, english) in cases {
    let stderr = "synthetic raw path\r\naudio_models_error:\(code)\r\n"
    #expect(L10n.Settings.speechModelDownloadMessage(stderr: stderr, lang: .zh) == chinese)
    #expect(L10n.Settings.speechModelDownloadMessage(stderr: stderr, lang: .en).contains(english))
  }
  #expect(L10n.Settings.speechModelDownloadMessage(stderr: "audio_models_error:disk\nprivate details", lang: .zh) == cases[4].1)
  #expect(L10n.Settings.speechModelDownloadMessage(stderr: "audio_models_error:unsupported", lang: .zh) == cases[4].1)
}

@Test func uploadResponseFailuresUseUploadCopyAndFixedDiagnosticCategories() throws {
  let cases: [(Int, UploadResponseFailure.Category, String)] = [
    (413, .tooLarge, "Pending records exceed the upload size limit"),
    (400, .rejected, "Background service rejected the request"),
    (500, .rejected, "Background service rejected the request"),
  ]
  for (status, category, diagnostic) in cases {
    let failure = UploadResponseFailure(status: status)
    let zh = AppLanguage.$scopedLanguage.withValue(.zh) { failure.message }
    try AppLanguage.$scopedLanguage.withValue(.en) {
      #expect(failure.category == category)
      #expect(L10n.Settings.backgroundIssue(zh) == failure.message)
      if status == 413 {
        #expect(zh == "待发送记录超过上传大小限制。")
        #expect(failure.message == "Pending records exceed the upload size limit.")
      }
      try withDiagnosticDirectory { directory in
        let fields = ["hubError": "synthetic private detail", "hubErrorCategory": failure.category.rawValue]
        try JSONSerialization.data(withJSONObject: fields).write(to: directory.appendingPathComponent("collector-status.json"))
        let text = summary(in: directory)
        #expect(text.contains("Save error category  \(diagnostic)"))
        #expect(!text.contains("synthetic private detail"))
      }
    }
  }
}
