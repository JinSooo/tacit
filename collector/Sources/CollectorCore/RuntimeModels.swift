import Foundation

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
    return ["assign":"整理活动", "thread_digest":"整理事项", "thread_brief":"事项摘要", "classify":"判断归属", "dedupe":"合并事项", "project":"项目进展", "project_brief":"项目摘要", "day":"每日回顾", "day_brief":"回顾摘要", "conversation_summary":"对话总结", "connection_test":"测试连接"][task] ?? "模型整理"
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
