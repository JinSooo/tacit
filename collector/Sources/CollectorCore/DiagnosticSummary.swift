import CoreFoundation
import Foundation

/// 从本机状态文件和后台状态响应选取可分享的诊断字段。
public enum DiagnosticSummary {
  private typealias Fields = [String: Any]

  private enum StartupCode: String {
    case db_key_missing, db_key_unreadable, db_open_failed, db_migration_failed, port_in_use, unknown
  }
  private struct StartupFailure: Decodable {
    let at: String?
    let code: String
    let message: String?
  }
  private struct SetupStatus: Decodable {
    let at: String
    let version: String
    let build: String
    let exit_code: Int
    let ok: Bool
  }

  private static let startupFile = "hub-startup-error.json"
  private static let setupFile = "setup-status.json"
  private static let eventLogs = ["hub.log", "distill.log", "collector.log"]
  private static let namedLogs = Set(eventLogs + ["setup.log"])
  private static let namedSources: Set<String> = [
    "mac.screen", "mac.app", "mac.clipboard", "mac.file", "mac.calendar", "mac.wechat",
    "mac.shell", "mac.git", "mac.browser", "mac.audio", "claude_code.session", "claude_desktop.session",
    "codex.session", "manual.note", "manual.correction", "manual.agent",
  ]

  /// 只在后台不可达时由调用方展示。准备状态只在启动错误文件缺席时兜底。
  public static func startupMessage(in dataDir: URL) -> String? {
    let file = dataDir.appendingPathComponent(startupFile)
    if FileManager.default.fileExists(atPath: file.path) {
      guard let failure = read(StartupFailure.self, at: file),
            timestamp(failure.at) != nil,
            StartupCode(rawValue: failure.code) != nil,
            let message = failure.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty else { return nil }
      return message
    }
    guard let setup = setupStatus(in: dataDir), !setup.ok else { return nil }
    return "后台准备没有完成（退出码 \(setup.exit_code)）"
  }

  public static func make(
    dataDir: URL, hubReachable: Bool, hubStatus: Data?, version: String?, build: String?,
    macOSVersion: OperatingSystemVersion, architecture: String,
    now: Date = Date(), timeZone: TimeZone = .current
  ) -> String {
    var lines = [
      "Tacit \(bundleIdentifier(version) ?? "开发版")，构建 \(bundleIdentifier(build) ?? "本地")",
      "macOS \(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)，\(architecture)",
      "生成于 \(LocalTime.iso(now, timeZone: timeZone))（\(timeZone.identifier)）",
      "",
      "后台服务\(hubReachable ? "可达" : "不可达")",
    ]
    func add(_ label: String, _ value: String?) {
      if let value { lines.append("\(label)  \(value)") }
    }
    if hubReachable, let hubStatus, let status = object(hubStatus) {
      let hub = status["hub"] as? Fields
      let database = status["database"] as? Fields
      add("运行时长", number(hub?["uptime_s"]).map { "\($0) 秒" })
      add("记录库大小", number(database?["bytes"]).map { "\($0) 字节" })

      let records = status["records"] as? Fields
      let sources = records?["by_source"] as? [Fields] ?? []
      var otherSources = 0
      for source in sources {
        guard let count = number(source["count"]) else { continue }
        let name: String
        if let id = source["source"] as? String, namedSources.contains(id) {
          name = id
        } else {
          otherSources += 1
          name = "其他来源 \(otherSources)"
        }
        let last = timestamp(source["last_received"]) ?? "未提供"
        add(name, "\(count) 条，最近入库 \(last)")
      }

      let distill = status["distill"] as? Fields
      add("整理最近响应", timestamp(distill?["heartbeat_at"]))
      add("最近一轮整理", timestamp(distill?["last_round_at"]))
      if let error = distill?["last_error"] as? Fields {
        add("最近模型错误", modelError(error["error"]))
      }
      if let cooldown = distill?["cooldown"] as? Fields, let until = cooldownEnd(cooldown["until"]) {
        let active = until > now
        let state = active ? "暂停重试至" : "暂停重试已结束于"
        let category = modelError(cooldown["kind"])
        add("模型重试", "\(state) \(LocalTime.iso(until, timeZone: timeZone))（\(category)）")
      }
      let usage = (status["llm_today"] as? Fields)?["total"] as? Fields
      add("今天模型调用", number(usage?["calls"]).map { "\($0) 次" })
      add("今天模型调用失败", number(usage?["failed"]).map { "\($0) 次" })
    } else if hubReachable {
      lines.append("未能读取后台详细状态")
    }
    if let failure = read(StartupFailure.self, at: dataDir.appendingPathComponent(startupFile)),
       let code = StartupCode(rawValue: failure.code) {
      add("启动错误类别", code.rawValue)
    }
    if let setup = setupStatus(in: dataDir) {
      lines.append("")
      lines.append("后台准备")
      add("时间", timestamp(setup.at))
      add("Tacit 版本", bundleIdentifier(setup.version))
      add("构建", bundleIdentifier(setup.build))
      add("结果", setup.ok ? "成功" : "失败")
      add("退出码", String(setup.exit_code))
    }
    if let data = readStatusFile(dataDir.appendingPathComponent("collector-status.json")),
       let capture = object(data) {
      lines.append("")
      lines.append("记录状态")
      add("更新时间", timestamp(capture["time"]))
      for (key, label) in [("axTrusted", "辅助功能权限"), ("ocrGranted", "录屏权限")] {
        add(label, boolean(capture[key]).map { $0 ? "已授权" : "未授权" })
      }
      for (key, label, unit) in [("queue", "等待保存", "条"), ("sent", "本次已保存", "条"),
                                 ("rejected", "拒收", "条"), ("dropped", "丢弃", "条"),
                                 ("outboxBytes", "待发送文件大小", "字节"), ("outboxDropped", "待发送记录丢弃", "条")] {
        add(label, number(capture[key]).map { "\($0) \(unit)" })
      }
      if let error = capture["hubError"] as? String { add("保存错误类别", deliveryError(error)) }
      if let transcription = capture["transcription"] as? Fields {
        add("等待转写", number(transcription["pending"]).map { "\($0) 段" })
        add("转写失败", number(transcription["failed"]).map { "\($0) 段" })
      }
      add("待发送记录仅在内存中重试", boolean(capture["outboxDegraded"]).map { $0 ? "是" : "否" })
    }
    let logs = dataDir.appendingPathComponent("logs")
    appendLogMetadata(in: logs, timeZone: timeZone, to: &lines)
    let events = recentEvents(in: logs)
    if !events.isEmpty { lines += ["", "近期日志事件"] + events }
    return lines.joined(separator: "\n")
  }

  private static func appendLogMetadata(in logs: URL, timeZone: TimeZone, to lines: inout [String]) {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    guard let files = try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: Array(keys),
                                                                   options: .skipsHiddenFiles) else { return }
    var entries: [String] = []
    var otherLogs = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let basename = file.lastPathComponent
      guard basename.range(of: #"\.log(?:\.[0-9]+)?(?:\.gz)?\z"#, options: .regularExpression) != nil else { continue }
      guard let info = try? file.resourceValues(forKeys: keys), info.isRegularFile == true,
            info.isSymbolicLink == false, let bytes = info.fileSize, let modified = info.contentModificationDate else { continue }
      let label: String
      if namedLogs.contains(basename) {
        label = basename
      } else {
        otherLogs += 1
        label = "其他日志 \(otherLogs)"
      }
      entries.append("\(label)  \(bytes) 字节，修改于 \(LocalTime.iso(modified, timeZone: timeZone))")
    }
    if !entries.isEmpty { lines += ["", "日志文件"] + entries }
  }

  /// 同一事件（除时间外字段都相同）合成一行并计次，免得一种错误每几秒刷一次就把别的事件挤出最近 30 条。
  private static func recentEvents(in logs: URL) -> [String] {
    var groups: [String: (at: Date, line: Fields, times: Int, order: Int)] = [:]
    var order = 0
    for name in eventLogs {
      for raw in tail(of: logs.appendingPathComponent(name)) {
        guard let (at, fields, key) = event(raw) else { continue }
        order += 1
        if var group = groups[key] {
          group.times += 1
          if at >= group.at { group.at = at; group.line = fields; group.order = order }
          groups[key] = group
        } else {
          groups[key] = (at, fields, 1, order)
        }
      }
    }
    return groups.values.sorted { lhs, rhs in
      if lhs.at != rhs.at { return lhs.at < rhs.at }
      return lhs.order < rhs.order
    }.suffix(30).compactMap { group in
      var line = group.line
      if group.times > 1 { line["times"] = group.times }
      guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
      return String(decoding: data, as: UTF8.self)
    }
  }

  private static func tail(of file: URL) -> [Data] {
    guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          info.isRegularFile == true, info.isSymbolicLink == false,
          let handle = try? FileHandle(forReadingFrom: file) else { return [] }
    defer { try? handle.close() }
    do {
      let size = try handle.seekToEnd()
      let count = min(size, 128 * 1024)
      // 多读一个字节，区分恰好落在换行处和读到半行。
      try handle.seek(toOffset: size > count ? size - count - 1 : 0)
      let data = try handle.read(upToCount: Int(count) + 1) ?? Data()
      let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
      return Array((size > count ? lines.dropFirst() : lines[...]).suffix(2000))
    } catch {
      return []
    }
  }

  /// 后台日志写 `location` + `code`，整理日志写 `step` + `category`，采集端写 `component` + `code`，统一成 component + code。
  private static func event(_ line: Data) -> (at: Date, fields: Fields, key: String)? {
    guard let fields = object(line),
          let code = diagnosticLabel(fields["code"]) ?? diagnosticLabel(fields["category"]) else { return nil }
    var safe: Fields = ["code": code]
    let at = timestamp(fields["at"])
    safe["component"] = diagnosticLabel(fields["component"]) ?? diagnosticLabel(fields["location"]) ?? diagnosticLabel(fields["step"])
    safe["name"] = diagnosticLabel(fields["name"])
    for (key, value) in fields where !["at", "component", "location", "step", "code", "category", "name", "times"].contains(key) {
      // 不复制自由文本、嵌套字段或凭据等敏感指标，即使值是数字。
      guard value is NSNumber, let key = diagnosticLabel(key),
            key.range(of: #"(?i)token|secret|key|password|authorization|credential|body|title|path|query|project|search"#,
                      options: .regularExpression) == nil else { continue }
      safe[key] = value
    }
    guard let identity = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) else { return nil }
    safe["at"] = at
    return (at.flatMap(ViewerTime.parse) ?? .distantPast, safe, String(decoding: identity, as: UTF8.self))
  }

  private static func modelError(_ value: Any?) -> String {
    let labels = [
      "timeout": "超时", "network": "网络不可用", "rate_limited": "请求太频繁", "quota": "额度用完",
      "auth": "密钥无效", "bad_request": "请求被拒绝", "server_error": "服务出错",
      "invalid_json": "返回不是 JSON", "schema_mismatch": "返回格式不对", "cli_missing": "没找到命令行工具",
      "cli_failed": "命令行调用失败", "usage_record_failed": "用量记录失败", "config_error": "模型配置无效", "unknown": "未知错误",
    ]
    guard let raw = value as? String, ModelErrorText.isCode(raw),
          let category = raw.split(separator: ":").first, let label = labels[String(category)] else { return "未知错误" }
    return "\(label)（\(raw)）"
  }

  private static func deliveryError(_ raw: String) -> String {
    // 旧采集端只保存错误原文。用固定前缀归类，不拼回剩余文本。
    if raw.hasPrefix("找不到 hub 的 token") || raw.hasPrefix("找不到后台服务的访问凭证") { return "未找到访问令牌" }
    if raw.hasPrefix("hub 连不上") || raw.hasPrefix("无法向 hub 发送") || raw.hasPrefix("连不上后台服务") { return "连不上后台服务" }
    if raw.hasPrefix("hub 返回 ") || raw.hasPrefix("后台服务拒绝了记录") { return "后台服务拒绝请求" }
    if raw.hasPrefix("后台未确认完整接收") { return "接收确认不完整" }
    if raw.hasPrefix("待发送记录无法安全保存") || raw.hasPrefix("有待发送记录无法安全保存") {
      return "待发送记录保存失败"
    }
    return "未知错误"
  }

  private static func setupStatus(in dataDir: URL) -> SetupStatus? {
    guard let status = read(SetupStatus.self, at: dataDir.appendingPathComponent(setupFile)),
          timestamp(status.at) != nil else { return nil }
    return status
  }

  private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
    guard let data = readStatusFile(url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static func readStatusFile(_ file: URL) -> Data? {
    let limit = 128 * 1024
    guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          info.isRegularFile == true, info.isSymbolicLink == false, let bytes = info.fileSize,
          bytes <= limit, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
    return data
  }

  private static func object(_ data: Data) -> Fields? {
    (try? JSONSerialization.jsonObject(with: data)) as? Fields
  }

  private static func timestamp(_ value: Any?) -> String? {
    guard let text = value as? String,
          text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#,
                     options: .regularExpression) != nil,
          ViewerTime.parse(text) != nil else { return nil }
    return text
  }

  private static func cooldownEnd(_ value: Any?) -> Date? {
    if let text = timestamp(value) { return ViewerTime.parse(text) }
    guard let millis = number(value)?.doubleValue, (0..<253_402_300_800_000).contains(millis) else { return nil }
    return Date(timeIntervalSince1970: millis / 1000)
  }

  private static func bundleIdentifier(_ value: String?) -> String? {
    guard let value, value.range(of: #"\A[0-9A-Za-z][0-9A-Za-z.-]{0,31}\z"#, options: .regularExpression) != nil,
          RecordRedaction.string(value).count == 0 else { return nil }
    return value
  }

  private static func diagnosticLabel(_ value: Any?) -> String? {
    guard let label = value as? String,
          label.range(of: #"\A[A-Za-z][A-Za-z0-9_.:-]{0,63}\z"#, options: .regularExpression) != nil,
          RecordRedaction.string(label).count == 0 else { return nil }
    return label
  }

  private static func number(_ value: Any?) -> NSNumber? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
    return value
  }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return value.boolValue
  }
}
