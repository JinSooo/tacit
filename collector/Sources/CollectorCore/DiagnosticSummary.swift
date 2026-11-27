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
  }

  private static let startupFile = "hub-startup-error.json"
  private static let setupFile = "setup-status.json"
  private static let eventLogs = ["hub.log", "distill.log", "collector.log"]
  private static let namedLogs = Set(eventLogs + ["setup.log"])
  private static let namedSources: Set<String> = [
    "mac.screen", "mac.app", "mac.clipboard", "mac.file", "mac.calendar", "mac.wechat",
    "mac.shell", "mac.git", "mac.browser", "mac.audio", "claude_desktop.session",
    "manual.note", "manual.correction", "manual.agent",
  ]

  /// 本次准备得到的原因优先，避免把上一次后台的错误当作本次失败。
  public static func startupMessage(in dataDir: URL) -> String? {
    let reason = setupStatus(in: dataDir)?.reason
    if let reason, reason != .unknown { return L10n.Settings.setupFailure(reason) }
    if let failure = read(StartupFailure.self, at: dataDir.appendingPathComponent(startupFile)),
       timestamp(failure.at) != nil, let code = StartupCode(rawValue: failure.code) {
      switch code {
      case .db_key_missing: return L10n.text(zh: "记录库的密钥不见了。请用之前的密钥备份恢复。", en: "The database key is missing. Restore it from your key backup.")
      case .db_key_unreadable: return L10n.Settings.setupFailure(.database)
      case .db_open_failed: return L10n.text(zh: "记录库打开失败。请确认密钥与记录库匹配。", en: "The database could not be opened. Check that its key matches the database.")
      case .db_migration_failed: return L10n.text(zh: "记录库升级失败。请保留记录库和迁移备份，并在设置 › 维护里复制诊断信息。", en: "The database upgrade failed. Keep the database and its backup, and copy diagnostics in Settings → Maintenance.")
      case .port_in_use: return L10n.Settings.setupFailure(.portInUse)
      case .unknown: break
      }
      return L10n.Settings.setupFailure(reason ?? .unknown)
    }
    return reason.map { L10n.Settings.setupFailure($0) }
  }

  public static func make(
    dataDir: URL, hubReachable: Bool, hubStatus: Data?, version: String?, build: String?,
    macOSVersion: OperatingSystemVersion, architecture: String,
    now: Date = Date(), timeZone: TimeZone = .current
  ) -> String {
    var lines = [
      L10n.text(zh: "Tacit \(bundleIdentifier(version) ?? "开发版")，构建 \(bundleIdentifier(build) ?? "本地")",
                en: "Tacit \(bundleIdentifier(version) ?? "dev"), build \(bundleIdentifier(build) ?? "local")"),
      "macOS \(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)，\(architecture)",
      L10n.text(zh: "生成于 \(LocalTime.iso(now, timeZone: timeZone))（\(timeZone.identifier)）", en: "Generated at \(LocalTime.iso(now, timeZone: timeZone)) (\(timeZone.identifier))"),
      "",
      L10n.text(zh: "后台服务\(hubReachable ? "可达" : "不可达")", en: hubReachable ? "Background service reachable" : "Background service unreachable"),
    ]
    func add(_ label: String, _ value: String?) {
      if let value { lines.append("\(label)  \(value)") }
    }
    if hubReachable, let hubStatus, let status = object(hubStatus) {
      let hub = status["hub"] as? Fields
      let database = status["database"] as? Fields
      add(L10n.text(zh: "运行时长", en: "Uptime"), number(hub?["uptime_s"]).map { L10n.text(zh: "\($0) 秒", en: "\($0) sec") })
      add(L10n.text(zh: "记录库大小", en: "Database size"), number(database?["bytes"]).map { L10n.text(zh: "\($0) 字节", en: "\($0) B") })

      let records = status["records"] as? Fields
      let sources = records?["by_source"] as? [Fields] ?? []
      var otherSources = 0
      for source in sources {
        guard let count = number(source["count"]) else { continue }
        let name: String
        if let id = source["source"] as? String, namedSources.contains(id) || AgentTools.session(source: id) != nil {
          name = id
        } else {
          otherSources += 1
          name = L10n.text(zh: "其他来源 \(otherSources)", en: "Other source \(otherSources)")
        }
        let last = timestamp(source["last_received"]) ?? L10n.text(zh: "未提供", en: "Unavailable")
        add(name, L10n.count(count.intValue, one: "%@ record, last received \(last)", other: "%@ records, last received \(last)", zh: "\(count) 条，最近入库 \(last)"))
      }

      let distill = status["distill"] as? Fields
      add(L10n.text(zh: "整理最近响应", en: "Last response from summarizer"), timestamp(distill?["heartbeat_at"]))
      add(L10n.text(zh: "最近一轮整理", en: "Last summary round"), timestamp(distill?["last_round_at"]))
      if let error = distill?["last_error"] as? Fields {
        add(L10n.text(zh: "最近模型错误", en: "Last model error"), modelError(error["error"]))
      }
      if let cooldown = distill?["cooldown"] as? Fields, let until = cooldownEnd(cooldown["until"]) {
        let active = until > now
        let state = active ? L10n.text(zh: "暂停重试至", en: "Retries paused until") : L10n.text(zh: "暂停重试已结束于", en: "Retry pause ended at")
        let category = modelError(cooldown["kind"])
        add(L10n.text(zh: "模型重试", en: "Model retries"), "\(state) \(LocalTime.iso(until, timeZone: timeZone))（\(category)）")
      }
      let usage = (status["llm_today"] as? Fields)?["total"] as? Fields
      add(L10n.text(zh: "今天模型调用", en: "Model calls today"), number(usage?["calls"]).map { L10n.text(zh: "\($0) 次", en: "\($0)") })
      add(L10n.text(zh: "今天模型调用失败", en: "Failed model calls today"), number(usage?["failed"]).map { L10n.text(zh: "\($0) 次", en: "\($0)") })
    } else if hubReachable {
      lines.append(L10n.text(zh: "未能读取后台详细状态", en: "Couldn't read background service status"))
    }
    if let failure = read(StartupFailure.self, at: dataDir.appendingPathComponent(startupFile)),
       let code = StartupCode(rawValue: failure.code) {
      add(L10n.text(zh: "启动错误类别", en: "Startup error category"), code.rawValue)
    }
    if let setup = setupStatus(in: dataDir) {
      lines.append("")
      lines.append(L10n.text(zh: "后台准备", en: "Background service setup"))
      add(L10n.text(zh: "时间", en: "Time"), timestamp(setup.at))
      add(L10n.text(zh: "Tacit 版本", en: "Tacit version"), bundleIdentifier(setup.version))
      add(L10n.text(zh: "构建", en: "Build"), bundleIdentifier(setup.build))
      add(L10n.text(zh: "结果", en: "Result"), setup.ok ? L10n.text(zh: "成功", en: "Succeeded") : L10n.text(zh: "失败", en: "Failed"))
      add(L10n.text(zh: "准备失败类别", en: "Setup failure category"), setup.reason?.rawValue)
      add(L10n.text(zh: "退出码", en: "Exit code"), String(setup.exit_code))
    }
    if let data = readStatusFile(dataDir.appendingPathComponent("collector-status.json")),
       let capture = object(data) {
      lines.append("")
      lines.append(L10n.text(zh: "记录状态", en: "Recording status"))
      add(L10n.text(zh: "更新时间", en: "Updated at"), timestamp(capture["time"]))
      for (key, label) in [("axTrusted", L10n.text(zh: "辅助功能权限", en: "Accessibility permission")), ("ocrGranted", L10n.text(zh: "录屏权限", en: "Screen Recording permission"))] {
        add(label, boolean(capture[key]).map { $0 ? L10n.text(zh: "已授权", en: "Granted") : L10n.text(zh: "未授权", en: "Not granted") })
      }
      for (key, label, unit) in [("queue", L10n.text(zh: "等待保存", en: "Waiting to be saved"), "条"), ("sent", L10n.text(zh: "本次已保存", en: "Saved this session"), "条"),
                                 ("rejected", L10n.text(zh: "拒收", en: "Rejected"), "条"), ("dropped", L10n.text(zh: "丢弃", en: "Discarded"), "条"),
                                 ("outboxBytes", L10n.text(zh: "待发送文件大小", en: "Pending upload size"), "字节"), ("outboxDropped", L10n.text(zh: "待发送记录丢弃", en: "Pending records discarded"), "条")] {
        add(label, number(capture[key]).map { "\($0) \(unit)" })
      }
      if let error = capture["hubError"] as? String { add(L10n.text(zh: "保存错误类别", en: "Save error category"), deliveryError(error)) }
      if let transcription = capture["transcription"] as? Fields {
        add(L10n.text(zh: "等待转写", en: "Awaiting transcription"), number(transcription["pending"]).map { L10n.text(zh: "\($0) 段", en: "\($0)") })
        add(L10n.text(zh: "转写失败", en: "Transcription failed"), number(transcription["failed"]).map { L10n.text(zh: "\($0) 段", en: "\($0)") })
      }
      add(L10n.text(zh: "待发送记录仅在内存中重试", en: "Pending uploads retried from memory"), boolean(capture["outboxDegraded"]).map { $0 ? L10n.text(zh: "是", en: "Yes") : L10n.text(zh: "否", en: "No") })
    }
    let logs = dataDir.appendingPathComponent("logs")
    appendLogMetadata(in: logs, timeZone: timeZone, to: &lines)
    let events = recentEvents(in: logs)
    if !events.isEmpty { lines += ["", L10n.text(zh: "近期日志事件", en: "Recent log events")] + events }
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
        label = L10n.text(zh: "其他日志 \(otherLogs)", en: "Other log \(otherLogs)")
      }
      entries.append(L10n.text(zh: "\(label)  \(bytes) 字节，修改于 \(LocalTime.iso(modified, timeZone: timeZone))", en: "\(label)  \(bytes) B, modified \(LocalTime.iso(modified, timeZone: timeZone))"))
    }
    if !entries.isEmpty { lines += ["", L10n.text(zh: "日志文件", en: "Log files")] + entries }
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
      "timeout": L10n.text(zh: "超时", en: "Timed out"), "network": L10n.text(zh: "网络不可用", en: "Network unavailable"), "rate_limited": L10n.text(zh: "请求太频繁", en: "Rate limited"), "quota": L10n.text(zh: "额度用完", en: "Quota exhausted"),
      "auth": L10n.text(zh: "密钥无效", en: "Invalid API key"), "bad_request": L10n.text(zh: "请求被拒绝", en: "Request rejected"), "server_error": L10n.text(zh: "服务出错", en: "Service error"),
      "invalid_json": L10n.text(zh: "返回不是 JSON", en: "Response is not JSON"), "schema_mismatch": L10n.text(zh: "返回格式不对", en: "Unexpected response format"), "cli_missing": L10n.text(zh: "没找到命令行工具", en: "Command-line tool missing"),
      "cli_failed": L10n.text(zh: "命令行调用失败", en: "Command failed"), "usage_record_failed": L10n.text(zh: "用量记录失败", en: "Usage logging failed"), "config_error": L10n.text(zh: "模型配置无效", en: "Invalid model settings"), "unknown": L10n.text(zh: "未知错误", en: "Unknown error"),
      "cli_not_logged_in": L10n.text(zh: "命令行工具未登录", en: "Command-line tool signed out"),
      "cli_outdated": L10n.text(zh: "命令行工具版本不兼容", en: "Incompatible command-line tool version"),
      "cli_model_unavailable": L10n.text(zh: "命令行模型不可用", en: "Command-line model unavailable"),
      "cli_network": L10n.text(zh: "命令行工具连不上模型服务", en: "Command-line tool can't reach the model service"),
      "cli_runtime_missing": L10n.text(zh: "找不到 Node.js", en: "Node.js missing"),
    ]
    guard let raw = value as? String, ModelErrorText.isCode(raw),
          let category = raw.split(separator: ":").first, let label = labels[String(category)] else { return L10n.text(zh: "未知错误", en: "Unknown error") }
    return "\(label)（\(raw)）"
  }

  private static func deliveryError(_ raw: String) -> String {
    // 旧采集端只保存错误原文。用固定前缀归类，不拼回剩余文本。
    if raw.hasPrefix("找不到 hub 的 token") || raw.hasPrefix("找不到后台服务的访问凭证") { return L10n.text(zh: "未找到访问令牌", en: "Access token missing") }
    if raw.hasPrefix("hub 连不上") || raw.hasPrefix("无法向 hub 发送") || raw.hasPrefix("连不上后台服务") { return L10n.text(zh: "连不上后台服务", en: "Can't reach background service") }
    if raw.hasPrefix("hub 返回 ") || raw.hasPrefix("后台服务拒绝了记录") { return L10n.text(zh: "后台服务拒绝请求", en: "Background service rejected the request") }
    if raw.hasPrefix("后台未确认完整接收") { return L10n.text(zh: "接收确认不完整", en: "Incomplete receipt confirmation") }
    if raw.hasPrefix("待发送记录无法安全保存") || raw.hasPrefix("有待发送记录无法安全保存") {
      return L10n.text(zh: "待发送记录保存失败", en: "Couldn't save pending records")
    }
    return L10n.text(zh: "未知错误", en: "Unknown error")
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
