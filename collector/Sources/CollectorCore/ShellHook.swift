import Foundation

/// 终端命令记录的钩子：在 ~/.zshrc 里 source 仓库的 plugins/shell/hook.zsh。
/// 开关打开时替用户加上这一行，关闭时删掉（AGENTS.md 2026-11-10）。只认这一行和我们写的注释，不动其他内容。
public enum ShellHook {
  static let marker = "# record-anything：记录终端命令"
  static let script = "plugins/shell/hook.zsh"

  public static func line(repo: String) -> String {
    "source \"\(repo.replacingOccurrences(of: "\"", with: "\\\""))/\(script)\""
  }

  /// 没被注释掉、source 任意位置 hook.zsh 的行（仓库挪过位置也算）。
  static func isHookLine(_ raw: Substring) -> Bool {
    let t = raw.trimmingCharacters(in: .whitespaces)
    guard !t.hasPrefix("#"), t.hasPrefix("source ") || t.hasPrefix(". ") else { return false }
    return t.contains(script)
  }

  public static func installed(in text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains(where: isHookLine)
  }

  /// 已有指向本仓库的钩子时原样返回；指向别处的旧钩子换成本仓库的。
  public static func adding(to text: String, repo: String) -> String {
    let wanted = line(repo: repo)
    if text.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.trimmingCharacters(in: .whitespaces) == wanted }) { return text }
    var out = removing(from: text)
    if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
    if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
    return out + marker + "\n" + wanted + "\n"
  }

  public static func removing(from text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var out: [Substring] = []
    for l in lines {
      if isHookLine(l) {
        // 一并去掉我们写在它上面的注释，以及因此多出来的空行。
        if out.last.map({ $0.trimmingCharacters(in: .whitespaces) == marker }) == true { out.removeLast() }
        if out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, out.count > 0 { out.removeLast() }
        continue
      }
      out.append(l)
    }
    return out.joined(separator: "\n")
  }
}
