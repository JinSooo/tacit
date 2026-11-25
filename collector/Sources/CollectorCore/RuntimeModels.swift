import Foundation

/// Mac 回顾和准备清单共用的后台整理状态。
public struct DistillHealth: Decodable, Equatable, Sendable {
  private struct LastError: Decodable, Equatable, Sendable {
    let error: String; let tier: String?; let recovered: Bool
    /// 出错那一档自己的最近成功；旧后台不给时用全局的 lastOkAt。
    let tierLastOkAt: String?
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
       let message = Self.problem(error.error, lastOk: (error.tierLastOkAt ?? lastOkAt).flatMap(ViewerTime.parse), now: now) { return .failing(message) }
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
    return "整理没能完成：" + ModelErrorText.plain(code)
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
    guard let task else { return "早期调用" }
    return ["assign":"整理活动", "thread_digest":"整理事项", "thread_brief":"事项摘要", "classify":"判断归属", "dedupe":"合并事项", "project":"项目进展", "project_brief":"项目摘要", "day":"每日时间线", "day_brief":"当天概述", "conversation_summary":"对话总结", "connection_test":"测试连接"][task] ?? "模型整理"
  }
  public var status: String {
    if applicationState == "discarded" { return "记录已变化，未采用" }
    if applicationState == "applied" { return "已用于更新" }
    if error != nil { return "失败" }
    if applicationState == "unknown" { return validationState == "passed" ? "调用成功，采用情况未记录" : "调用失败" }
    if validationState == "passed" { return "校验通过，待确认采用" }
    if providerState == "sending" { return "等待模型返回" }
    if providerState == "returned" { return "已返回，校验未通过" }
    return "准备发送"
  }
  public var elapsed: String { ms.map { $0 < 1000 ? "\(Int($0)) ms" : String(format: "%.1f 秒", $0 / 1000) } ?? "进行中" }
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
    ["deleted":"删除历史记录时，调用正文已一并清空。", "expired":"已超过 7 天，正文已清除。", "not_recorded":"这次调用发生时没有保存正文，无法还原当时发送的内容。", "unavailable":"当时未能保存正文。"][state]
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
    ["auth", "quota", "bad_request", "config_error", "cli_missing", "cli_failed"].contains(category(code))
  }

  public static func isCode(_ text: String) -> Bool {
    text.range(of: #"\A[a-z_]+(?::[1-5][0-9]{2})?\z"#, options: .regularExpression) != nil
  }

  /// 不是错误码的文字（例如后台给的中文原因）原样返回。
  public static func plain(_ code: String) -> String {
    guard isCode(code) else { return code }
    switch category(code) {
    case "auth": return "API key 没设置或无效；用账号登录的，请确认已登录。"
    case "quota": return "模型服务的额度用完了，充值或额度恢复后会自动继续。"
    case "bad_request": return "模型服务拒绝了请求，请检查模型名、地址和思考强度。"
    case "config_error": return "模型设置有问题，请检查后重新保存。"
    // 默认模型借用本机的 Claude Code；朋友的 Mac 上常常没装（2026-11-25 虚拟机实测）。
    case "cli_missing": return "这台 Mac 上没找到 Claude Code 或 Codex。装好并登录，或改填 API。"
    case "cli_failed": return "命令行工具调用失败，请确认已安装并登录。"
    case "network": return "连不上模型服务，请检查网络和地址。"
    case "rate_limited": return "请求太频繁，模型服务暂时限流，稍后会自动重试。"
    case "timeout": return "模型服务一直没有回应，请检查网络或稍后再试。"
    case "server_error": return "模型服务暂时出错，稍后会自动重试。"
    case "schema_mismatch", "invalid_json": return "模型返回的内容不合格式，可以换个模型试试。"
    case "usage_record_failed": return "整理记录没能保存，请检查磁盘空间。"
    default: return "原因不明，请检查模型设置。"
    }
  }
}
