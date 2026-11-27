import Foundation

/// 与 hub/src/redact.ts 的入库规则一致；加密待发送文件也只保存脱敏后的文字。
/// schema/fixtures/redaction.json 保存共用的兼容性样例。
public enum RecordRedaction {
  private static let patterns: [(String, String)] = [
    ("私钥", #"-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY)-----[\s\S]*?-----END \1-----"#),
    ("AWS", #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
    ("GitHub", #"\b(?:gh[pors]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#),
    ("Anthropic", #"\bsk-ant-[A-Za-z0-9_-]{16,}"#),
    ("OpenAI", #"\bsk-(?!ant-)[A-Za-z0-9_-]{16,}"#),
    ("Slack", #"\bxox[a-z]-[A-Za-z0-9-]{10,}"#),
    ("Stripe", #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#),
    ("Google", #"\bAIza[0-9A-Za-z_-]{35}"#),
    ("GitLab", #"\bglpat-[A-Za-z0-9_-]{20,}"#),
    ("HuggingFace", #"\bhf_[A-Za-z0-9]{30,}\b"#),
    ("JWT", #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{8,}\b"#),
  ]
  private static func replace(_ input: String, pattern: String, transform: (NSTextCheckingResult, NSString) -> String?) -> (String, Int) {
    let re = try! NSRegularExpression(pattern: pattern)
    var output = input, count = 0
    let original = input as NSString
    for match in re.matches(in: input, range: NSRange(location: 0, length: original.length)).reversed() {
      if let replacement = transform(match, original), let range = Range(match.range, in: output) {
        output.replaceSubrange(range, with: replacement); count += 1
      }
    }
    return (output, count)
  }
  public static func string(_ input: String) -> (text: String, count: Int) {
    // ICU 不支持 JS 的无限长 lookbehind，匹配时捕获前缀并原样保留。
    var (text, count) = replace(input, pattern: #"(?i)(\b(?:Proxy-)?Authorization:[ \t]*Basic[ \t]+)[A-Za-z0-9+/]+=*"#) { m, s in
      s.substring(with: m.range(at: 1)) + "[已脱敏:Basic]"
    }
    for (type, pattern) in patterns {
      let r = replace(text, pattern: pattern) { _, _ in "[已脱敏:\(type)]" }
      text = r.0; count += r.1
    }
    let mapKey = replace(text, pattern: #"(?i)([?&](?:amp;)?tk=)[a-f0-9]{32}(?![a-f0-9])"#) { m, s in
      s.substring(with: m.range(at: 1)) + "[已脱敏:地图密钥]"
    }
    text = mapKey.0; count += mapKey.1
    let bearer = replace(text, pattern: #"(?i)(\b(?:Bearer|Token)\s+)[A-Za-z0-9._~+/\-]{16,}=*"#) { m, s in
      s.substring(with: m.range(at: 1)) + "[已脱敏:Bearer]"
    }
    text = bearer.0; count += bearer.1
    let basic = replace(text, pattern: #"(\bBasic[ \t]+)([A-Za-z0-9+/]{12,}={0,2})(?![A-Za-z0-9+/=])"#) { m, s in
      let value = s.substring(with: m.range(at: 2))
      guard value.utf8.count % 4 == 0, let data = Data(base64Encoded: value),
            let decoded = String(data: data, encoding: .utf8), decoded.contains(":"),
            !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 0xfffd }) else { return nil }
      return s.substring(with: m.range(at: 1)) + "[已脱敏:Basic]"
    }
    text = basic.0; count += basic.1
    let url = replace(text, pattern: #"(?i)(\b[a-z][a-z0-9+.-]*://[^\s/@:]+:)([^\s/@]+)(@)"#) { m, s in
      s.substring(with: m.range(at: 1)) + "[已脱敏:URL密码]@"
    }
    text = url.0; count += url.1
    let urlCredentials = replace(text, pattern: #"(?i)(\b(?:https?|wss?|socks(?:4a?|5h?)?)://)[^\s/@:?#]+@(?=[^\s/@?#])"#) { m, s in
      s.substring(with: m.range(at: 1)) + "[已脱敏:URL凭据]@"
    }
    text = urlCredentials.0; count += urlCredentials.1
    let assignment = replace(text, pattern: #"(?i)((?:["']?)(?:password|passwd|pwd|token|access_token|refresh_token|api[_-]?key|secret|client_secret)["']?\s*[:=]\s*)(["']?)([A-Za-z0-9_+/.=~%!@#$^&*?:\-]{16,})\2"#) { m, s in
      let value = s.substring(with: m.range(at: 3)), quote = s.substring(with: m.range(at: 2))
      guard classes(value) >= 2, entropy(value) >= 3.5 else { return nil }
      return s.substring(with: m.range(at: 1)) + quote + "[已脱敏:赋值密钥]" + quote
    }
    text = assignment.0; count += assignment.1
    let pair = replace(text, pattern: #"(?i)((?:账号|帐号|账户|用户名|\busername|\baccount)[ \t]*(?:[/／][ \t]*)?(?:密码|口令|password|passwd|pwd)[ \t]*(?:是|为)?[ \t]*[:：=][ \t\r\n]*)([^\s/／:：=]{1,128}(?:[ \t]*[/／][ \t]*|[ \t]+|\r?\n[ \t]*))([A-Za-z0-9_+/.=~%!@#$^&*?:\-]{1,128})"#) { m, s in
      s.substring(with: m.range(at: 1)) + "[已脱敏:账号密码]"
    }
    text = pair.0; count += pair.1
    let short = replace(text, pattern: #"(?i)((?:\b(?:password|passwd|pwd)\b|密码|口令)["']?[ \t]*(?:[:：=]|为[:：]?|是[:：]?|\r?\n)[ \t]*)(["']?)([A-Za-z0-9_+/.=~%!@#$^&*?:\-]{4,128})\2"#) { m, s in
      let value = s.substring(with: m.range(at: 3)), quote = s.substring(with: m.range(at: 2))
      guard classes(value) >= 2 || matches(value, #"^\d+$"#) else { return nil }
      return s.substring(with: m.range(at: 1)) + quote + "[已脱敏:密码]" + quote
    }
    text = short.0; count += short.1
    let loginLine = replace(text, pattern: #"(?i)(https?\\?[ \t\r\n]*:[ \t\r\n]*//[^\s]+[ \t\r\n]+)([^\s]{1,64})([ \t\r\n]+)([A-Za-z0-9_+/.=~%!@#$^&*?:\-]{8,128})"#) { m, s in
      guard classes(s.substring(with: m.range(at: 4))) >= 3 else { return nil }
      return s.substring(with: m.range(at: 1)) + s.substring(with: m.range(at: 2)) + s.substring(with: m.range(at: 3)) + "[已脱敏:密码]"
    }
    text = loginLine.0; count += loginLine.1
    let lines = replace(text, pattern: #"(^|\n)([ \t]*)([^\s\n]+)([ \t]*)(?=\r?\n|$)"#) { m, s in
      let start = max(0, m.range.location - 300), end = min(s.length, NSMaxRange(m.range) + 100)
      let nearby = s.substring(with: NSRange(location: start, length: end - start))
      guard clipboardPassword(s.substring(with: m.range(at: 3))), matches(nearby, #"(?i)账号|帐号|用户名|密码|口令|\b(?:password|login|sign in)\b"#) else { return nil }
      return s.substring(with: m.range(at: 1)) + s.substring(with: m.range(at: 2)) + "[已脱敏:密码]" + s.substring(with: m.range(at: 4))
    }
    return (lines.0, count + lines.1)
  }
  private static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
  private static func classes(_ value: String) -> Int { ["[a-z]", "[A-Z]", "[0-9]", "[^A-Za-z0-9]"].filter { matches(value, $0) }.count }
  private static func entropy(_ value: String) -> Double {
    let groups = Dictionary(grouping: value, by: { $0 })
    return groups.values.reduce(0) { sum, g in let p = Double(g.count) / Double(value.count); return sum - p * log2(p) }
  }
  private static func clipboardPassword(_ value: String) -> Bool {
    guard (8...64).contains(value.count), matches(value, #"^[\x21-\x7e]+$"#) else { return false }
    let exclusions = [#"(?i)^(?:[a-z][a-z0-9+.-]*://|www\.)"#, #"^[^@]+@[^@]+\.[^@]+$"#,
      #"(?i)^(?:[a-z]:[\\/]|[\\/]|~[\\/]|\.{1,2}[\\/])"#, #"^[^\\/:*?"<>|]+(?:[\\/][^\\/:*?"<>|]+)+$"#,
      #"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
      #"\.[A-Za-z][A-Za-z0-9]{0,5}$"#, #"^[A-Za-z0-9]+(?:[-_.][A-Za-z0-9]+)+$"#, #"^(?:[A-Za-z]+|[0-9]+)$"#]
    return !exclusions.contains { matches(value, $0) } && classes(value) >= 3
  }
  public static func record(_ input: Record) -> Record {
    var record = input, count = 0
    func redact(_ value: String) -> String { let r = string(value); count += r.count; return r.text }
    let candidate = input.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let password = input.source == "mac.clipboard" && clipboardPassword(candidate) ? candidate : nil
    func mainText(_ value: String) -> String {
      let clean = redact(value)
      guard let password else { return clean }
      let parts = clean.components(separatedBy: password); count += parts.count - 1
      return parts.joined(separator: "[已脱敏:密码]")
    }
    record.title = mainText(record.title); record.body = mainText(record.body)
    if var context = record.context {
      context.app = context.app.map(redact); context.window = context.window.map(redact)
      context.url = context.url.map(redact); context.chat = context.chat.map(redact)
      context.extra = context.extra?.mapValues { value in
        if case .string(let s) = value { return .string(redact(s)) }; return value
      }
      record.context = context
    }
    record.people = record.people?.map(redact)
    // source_ref 不参与界面展示，但也可能由来源填写成包含密码的 URL。
    record.source_ref = record.source_ref.map(redact)
    record.redactions = (record.redactions ?? 0) + count
    if count > 0 && record.sensitivity == "normal" { record.sensitivity = "redacted" }
    return record
  }
}
