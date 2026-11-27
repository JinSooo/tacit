import Foundation

/// Mac 回顾和准备清单共用的后台整理状态。
public struct DistillHealth: Decodable, Equatable, Sendable {
  private struct LastError: Decodable, Equatable, Sendable {
    let error: String; let tier: String?; let recovered: Bool
    /// 出错那一档自己的最近成功；旧后台缺字段时用全局时间。
    let tierLastOkAt: String?
    let hasTierLastOkAt: Bool

    private enum CodingKeys: String, CodingKey { case error, tier, recovered, tierLastOkAt }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      error = try values.decode(String.self, forKey: .error)
      tier = try values.decodeIfPresent(String.self, forKey: .tier)
      recovered = try values.decode(Bool.self, forKey: .recovered)
      tierLastOkAt = try values.decodeIfPresent(String.self, forKey: .tierLastOkAt)
      hasTierLastOkAt = values.contains(.tierLastOkAt)
    }
  }
  public let lastOkAt: String?
  private let lastError: LastError?
  private let lastRoundAt: String?
  private let heartbeatAt: String?

  /// failing 带的是给用户看的一句话，不含错误码。
  public enum State: Equatable { case working, waiting, failing(String) }
  public var state: State { state(at: Date()) }

  public func state(at now: Date) -> State {
    if let error = lastError, !error.recovered,
       let message = Self.problem(error.error, lastOk: (error.hasTierLastOkAt ? error.tierLastOkAt : lastOkAt).flatMap(ViewerTime.parse), now: now) { return .failing(message) }
    return lastOkAt == nil ? .waiting : .working
  }

  /// 出问题的那一档（minute / hour / day），旧后台不给时为 nil。
  public var failingTier: String? {
    guard case .failing = state else { return nil }
    return lastError?.tier
  }

  /// 用户能处理的错误马上说；格式不对、超时这类下一轮会自己重试的，整理连续 1 小时都没成功才说（2026-11-25）。
  static func problem(_ code: String, lastOk: Date?, now: Date) -> String? {
    if !ModelErrorText.needsUser(code), let lastOk, now.timeIntervalSince(lastOk) < 3600 { return nil }
    return L10n.text(zh: "整理没能完成：", en: "Summarizing failed. ") + ModelErrorText.plain(code)
  }

  public func isResponding(at now: Date) -> Bool {
    guard let heartbeat = heartbeatAt.flatMap(ViewerTime.parse) else { return false }
    return (0...90).contains(now.timeIntervalSince(heartbeat))
  }

  /// 常驻后台按上一轮开始时间加 15 分钟调度。长任务可能让这一轮延后。
  public func nextRound(after now: Date) -> Date? {
    guard isResponding(at: now), let last = lastRoundAt.flatMap(ViewerTime.parse), last <= now else { return nil }
    let next = last.addingTimeInterval(15 * 60)
    return next > now ? next : nil
  }
}

public struct ModelCall: Decodable, Identifiable, Sendable {
  public let id: String
  public let at: String
  public let task: String?
  public let model: String?
  public let providerState: String
  public let validationState: String
  public let applicationState: String
  public let contentState: String
  public let ms: Double?
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let error: String?
  public var date: Date? { ViewerTime.parse(at) }
  public var title: String {
    guard let task else { return L10n.text(zh: "早期调用", en: "Earlier call") }
    switch task {
    case "assign": return L10n.text(zh: "整理活动", en: "Summarize activities")
    case "thread_digest": return L10n.text(zh: "整理事项", en: "Summarize tasks")
    case "thread_brief": return L10n.text(zh: "事项摘要", en: "Task summary")
    case "classify": return L10n.text(zh: "判断归属", en: "Classify activities")
    case "dedupe": return L10n.text(zh: "合并事项", en: "Merge tasks")
    case "project": return L10n.text(zh: "项目进展", en: "Project progress")
    case "project_brief": return L10n.text(zh: "项目摘要", en: "Project summary")
    case "day": return L10n.text(zh: "每日时间线", en: "Daily timeline")
    case "day_brief": return L10n.text(zh: "当天概述", en: "Day overview")
    case "conversation_summary": return L10n.text(zh: "对话总结", en: "Conversation summary")
    case "connection_test": return L10n.text(zh: "测试连接", en: "Test connection")
    default: return L10n.text(zh: "模型整理", en: "Summarize with model")
    }
  }
  public var status: String {
    if applicationState == "discarded" { return L10n.text(zh: "记录已变化，未采用", en: "Records changed, result discarded") }
    if applicationState == "applied" { return L10n.text(zh: "已用于更新", en: "Applied") }
    if error != nil { return L10n.text(zh: "失败", en: "Failed") }
    if applicationState == "unknown" { return validationState == "passed" ? L10n.text(zh: "调用成功，采用情况未记录", en: "Call succeeded, application status unavailable") : L10n.text(zh: "调用失败", en: "Call failed") }
    if validationState == "passed" { return L10n.text(zh: "校验通过，待确认采用", en: "Validation passed, awaiting application") }
    if providerState == "sending" { return L10n.text(zh: "等待模型返回", en: "Waiting for the model") }
    if providerState == "returned" { return L10n.text(zh: "已返回，校验未通过", en: "Response received, validation failed") }
    return L10n.text(zh: "准备发送", en: "Preparing to send")
  }
  public var elapsed: String { ms.map { $0 < 1000 ? "\(Int($0)) ms" : String(format: L10n.text(zh: "%.1f 秒", en: "%.1f sec"), $0 / 1000) } ?? L10n.text(zh: "进行中", en: "In progress") }
}

public struct ModelCallPage: Decodable, Sendable {
  public let calls: [ModelCall]
  public let nextCursor: String?
}
public struct CallSnapshot: Decodable, Sendable {
  public let kind: String
  public let transport: String?
  public let contentState: String
  public let request: JSONValue?
  public let response: String?
  public let responseTruncated: FlexBool
  public let redactions: Int
  public var missing: String? { Self.missing(contentState) }
  public static func missing(_ state: String) -> String? {
    switch state {
    case "deleted": return L10n.text(zh: "删除历史记录时，调用正文已一并清空。", en: "The call content was cleared when its history records were deleted.")
    case "expired": return L10n.text(zh: "已超过 7 天，正文已清除。", en: "The call content was cleared after 7 days.")
    case "not_recorded": return L10n.text(zh: "这次调用发生时没有保存正文，无法还原当时发送的内容。", en: "This call has no saved content.")
    case "unavailable": return L10n.text(zh: "当时未能保存正文。", en: "The call content couldn't be saved.")
    default: return nil
    }
  }
  public var inputText: String {
    if kind == "context", case .object(let fields) = request { return fields["text"]?.text ?? "" }
    return request?.prettyJSON ?? ""
  }
}
public struct BackgroundLogPage: Decodable, Sendable {
  public let events: [JSONValue]
  public let skipped: Int
  public let modifiedAt: String?
}

extension JSONValue {
  public var prettyJSON: String {
    func value(_ v: JSONValue) -> Any {
      switch v {
      case .string(let s): return s
      case .number(let n): return n
      case .bool(let b): return b
      case .array(let a): return a.map(value)
      case .object(let o): return o.mapValues(value)
      case .null: return NSNull()
      }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: value(self), options: [.prettyPrinted,.sortedKeys,.fragmentsAllowed]),
          let text = String(data:data,encoding:.utf8) else { return "" }
    return text
  }
}

/// 后台模型错误码（如 `auth:401`、`schema_mismatch`）给用户看的一句话。界面不显示错误码，诊断信息里才保留原码。
public enum ModelErrorText {
  static func category(_ code: String) -> String { code.split(separator: ":").first.map(String.init) ?? code }

  /// 要用户动手才能好的错误；其余的下一轮会自己重试。
  public static func needsUser(_ code: String) -> Bool {
    ["auth", "quota", "bad_request", "config_error", "cli_missing", "cli_failed",
     "cli_not_logged_in", "cli_outdated", "cli_model_unavailable", "cli_runtime_missing"].contains(category(code))
  }

  public static func isCode(_ text: String) -> Bool {
    text.range(of: #"\A[a-z_]+(?::[1-5][0-9]{2})?\z"#, options: .regularExpression) != nil
  }

  /// 不是错误码的文字（例如后台给的中文原因）原样返回。
  public static func plain(_ code: String) -> String { plain(code, lang: .current) }

  public static func plain(_ code: String, lang: AppLanguage) -> String {
    guard isCode(code) else { return code }
    switch category(code) {
    case "auth": return L10n.text(zh: "API key 没设置或无效；用账号登录的，请确认已登录。", en: "Check your API key or sign in if you connect with an account.", lang: lang)
    case "quota": return L10n.text(zh: "模型服务的额度用完了，充值或额度恢复后会自动继续。", en: "The model service quota ran out. Summarizing will resume when quota is available.", lang: lang)
    case "bad_request": return L10n.text(zh: "模型服务拒绝了请求，请检查模型名、地址和思考强度。", en: "The model service rejected the request. Check the model name, address, and reasoning effort.", lang: lang)
    case "config_error": return L10n.text(zh: "模型设置有问题，请检查后重新保存。", en: "Check your model settings and save them again.", lang: lang)
    // 默认模型借用本机的 Claude Code；朋友的 Mac 上常常没装（2026-11-25 虚拟机实测）。
    case "cli_missing": return L10n.text(zh: "没找到所选的命令行工具，请安装并登录，或改用 API。", en: "Install and sign in to the selected command-line tool, or switch to an API provider.", lang: lang)
    case "cli_not_logged_in": return L10n.text(zh: "所选的命令行工具没登录，请在终端登录后再测试。", en: "Sign in to the selected command-line tool in Terminal, then test again.", lang: lang)
    case "cli_outdated": return L10n.text(zh: "命令行工具不支持所需的参数，请升级后再试。", en: "The command-line tool doesn't support a required option. Update it and try again.", lang: lang)
    case "cli_model_unavailable": return L10n.text(zh: "当前账号用不了所选的模型，请换个模型名再试。", en: "The selected model is unavailable to your account. Try a different model name.", lang: lang)
    case "cli_network": return L10n.text(zh: "命令行工具连不上模型服务，请检查网络或代理。", en: "The command-line tool couldn't reach the model service. Check your network or proxy.", lang: lang)
    case "cli_runtime_missing": return L10n.text(zh: "找不到命令行工具需要的 Node.js，请重新安装该工具或 Node.js。", en: "The command-line tool couldn't find Node.js. Reinstall the tool or Node.js.", lang: lang)
    case "cli_failed": return L10n.text(zh: "命令行工具没能完成请求，可以展开查看原因或重新测试。", en: "The command-line tool couldn't complete the request. View the reason or test again.", lang: lang)
    case "network": return L10n.text(zh: "连不上模型服务，请检查地址、网络或代理。", en: "Can't reach the model service. Check the service address, network, or proxy.", lang: lang)
    case "rate_limited": return L10n.text(zh: "请求太频繁，模型服务暂时限流，稍后会自动重试。", en: "The model service is limiting requests. Tacit will retry automatically.", lang: lang)
    case "timeout": return L10n.text(zh: "模型服务一直没有回应，请检查网络或稍后再试。", en: "The model service didn't respond. Check your network or try again later.", lang: lang)
    case "server_error": return L10n.text(zh: "模型服务暂时出错，稍后会自动重试。", en: "The model service encountered an error. Tacit will retry automatically.", lang: lang)
    case "schema_mismatch", "invalid_json": return L10n.text(zh: "模型返回的内容不合格式，可以换个模型试试。", en: "The model returned an unexpected format. Try a different model.", lang: lang)
    case "usage_record_failed": return L10n.text(zh: "整理记录没能保存，请检查磁盘空间。", en: "The summary couldn't be saved. Check your disk space.", lang: lang)
    default: return L10n.text(zh: "原因不明，请检查模型设置。", en: "An unexpected error occurred. Check your model settings.", lang: lang)
    }
  }
}
