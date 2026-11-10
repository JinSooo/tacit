import CryptoKit
import Foundation

/// OCR 识别出的一行文字。坐标是窗口内的点，原点在左上。
public struct OCRLine: Equatable, Sendable {
  public var text: String
  public var minX: Double
  public var maxX: Double
  public var y: Double
  public var height: Double
  public init(_ text: String, minX: Double, maxX: Double, y: Double, height: Double) {
    self.text = text; self.minX = minX; self.maxX = maxX; self.y = y; self.height = height
  }
  public var midX: Double { (minX + maxX) / 2 }
}

public struct WeChatMessage: Equatable, Sendable {
  /// 群聊里是昵称，单聊里是对方（会话名）；自己发的为 nil。
  public var sender: String?
  public var fromMe: Bool
  public var text: String
  /// 这条消息上方最近的时间分隔（界面原文，例如"昨天 15:33"）。
  public var shownTime: String
}

public struct WeChatView: Equatable, Sendable {
  public var chat: String
  public var isGroup: Bool
  public var messages: [WeChatMessage]
}

/// 微信 4.x 主窗口的版面（2026-11-10 用真实截图实测，深色模式，窗口宽 1053 和 1728 两种）：
/// - 左边是图标栏和会话列表，列表右侧的时间列右对齐，右边缘在 x≈280；
/// - 聊天区标题在 x≈304、y≈20，群聊标题末尾带"（人数）"；
/// - 别人的昵称在标题左边缘右侧约 53pt，正文约 66pt；昵称下面紧跟正文，引用框在昵称那一列但下面不跟正文；
/// - 自己发的消息右对齐，右边缘距窗口右边约 84pt；时间分隔在聊天区居中；
/// - 聊天里发的截图，图里的小字只有 6–9pt 高，正常文字 13–20pt；
/// - 输入框里的草稿从标题左边缘附近开始。
/// 这些都是相对标题左边缘和窗口右边缘的固定距离，不随窗口宽度缩放。浅色模式和窄窗口没有实测。
public enum WeChatLayout {
  static let titleMaxY = 45.0
  static let nicknameOffset = 40.0...60.0
  static let textOffset = 61.0...75.0
  static let ownRightMargin = 70.0...100.0
  static let minTextHeight = 10.0
  static let bubbleLineGap = 32.0

  /// 时间分隔或会话列表里的时间："15:33""昨天 15:33""Yesterday 12:17""11/03""星期二"。
  static func looksLikeTime(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.range(of: #"^\d{1,2}[:：]\d{2}$"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"^\d{1,4}[/年-]\d{1,2}([/月-]\d{1,2}日?)?( \d{1,2}:\d{2})?$"#, options: .regularExpression) != nil { return true }
    if t.range(of: #"^(昨天|前天|今天|星期.|周.|Yesterday|Today|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)( ?\d{1,2}:\d{2})?$"#, options: .regularExpression) != nil { return true }
    return false
  }

  /// 聊天区标题：窗口顶部、横向最靠左但在会话列表右边的一行。没有会话列表（窄窗口）时就是顶部最左的一行。
  static func title(_ lines: [OCRLine], width: Double) -> OCRLine? {
    let top = lines.filter { $0.y < titleMaxY && $0.height >= 12 && !looksLikeTime($0.text) && $0.maxX < width - 60 }
    let left = sidebarRight(lines, width: width) ?? 0
    return top.filter { $0.minX > left }.min { $0.minX < $1.minX }
  }

  /// 会话列表右边缘：窗口左半边里，三行以上右边缘对齐（±4pt）的时间列。
  public static func sidebarRight(_ lines: [OCRLine], width: Double) -> Double? {
    let times = lines.filter { looksLikeTime($0.text) && $0.maxX < width * 0.5 && $0.y > titleMaxY }
    var best: (x: Double, n: Int)?
    for t in times {
      let n = times.filter { abs($0.maxX - t.maxX) <= 4 }.count
      if n >= 3, best.map({ n > $0.n }) ?? true { best = (t.maxX, n) }
    }
    return best?.x
  }

  /// 通用 OCR 用：去掉会话列表和顶部、底部以外的杂项，只留聊天区的文字。认不出版面时原样返回。
  public static func chatAreaLines(_ lines: [OCRLine], width: Double) -> [OCRLine] {
    guard let right = sidebarRight(lines, width: width) ?? title(lines, width: width).map({ $0.minX - 15 }) else { return lines }
    return lines.filter { $0.minX > right + 5 }
  }

  /// 把一屏聊天拆成消息。认不出聊天区标题时返回 nil（不是聊天界面，例如通讯录、朋友圈）。
  /// 第一个时间分隔之上的消息不返回：它们的时间看不到，算不出稳定的指纹，等往上翻到能看见分隔时再记。
  /// 一屏里没有任何时间分隔时全部返回，时间留空。
  public static func parse(_ lines: [OCRLine], width: Double, height: Double) -> WeChatView? {
    guard let title = title(lines, width: width) else { return nil }
    let left = title.minX
    var chat = title.text.trimmingCharacters(in: .whitespaces)
    var isGroup = false
    if let r = chat.range(of: #"\s*[（(]\d+[）)]$"#, options: .regularExpression) { chat.removeSubrange(r); isGroup = true }
    guard !chat.isEmpty else { return nil }
    let chatCenter = (left - 15 + width) / 2
    let sendRow = lines.filter { $0.minX > width - 100 && $0.y > height * 0.7 }.map(\.y).min()
    let body = lines
      .filter { $0.y > title.y + title.height + 4 && $0.minX > left - 10 && $0.height >= minTextHeight }
      .filter { l in sendRow.map { l.y < $0 - 12 } ?? true }
      // 输入框草稿：从标题左边缘附近开始，在别人消息那一列的左边。
      .filter { $0.minX > left + 30 }
      .sorted { $0.y < $1.y }

    enum Kind { case time, nickname, other, mine, unknown }
    func kind(_ i: Int) -> Kind {
      let l = body[i], dx = l.minX - left
      if abs(l.midX - chatCenter) < 30, looksLikeTime(l.text) { return .time }
      if ownRightMargin.contains(width - l.maxX), l.minX > chatCenter - 40 { return .mine }
      if textOffset.contains(dx) { return .other }
      if nicknameOffset.contains(dx) {
        // 昵称下面紧跟正文；否则是挂在上一条消息下面的引用框。
        if i + 1 < body.count, textOffset.contains(body[i + 1].minX - left), body[i + 1].y - l.y < 45 { return .nickname }
        return .unknown
      }
      return .unknown
    }

    var messages: [WeChatMessage] = []
    var shown: String?, sawTime = false, nickname: String?
    var current: (msg: WeChatMessage, lastY: Double, column: Kind)?
    func flush() {
      if let c = current { messages.append(c.msg) }
      current = nil
    }
    for i in body.indices {
      let l = body[i], k = kind(i)
      switch k {
      case .time:
        flush(); shown = l.text.trimmingCharacters(in: .whitespaces); sawTime = true; nickname = nil
      case .nickname:
        flush(); nickname = l.text.trimmingCharacters(in: .whitespaces)
      case .other, .mine:
        let text = l.text.trimmingCharacters(in: .whitespaces)
        if let c = current, c.column == k, l.y - c.lastY <= bubbleLineGap {
          current!.msg.text += "\n" + text; current!.lastY = l.y; continue
        }
        flush()
        let sender = k == .mine ? nil : (isGroup ? nickname : chat)
        current = (WeChatMessage(sender: sender, fromMe: k == .mine, text: text, shownTime: shown ?? ""), l.y, k)
        if k == .other { nickname = nil }
      case .unknown:
        flush()
      }
    }
    flush()
    if sawTime { messages = messages.filter { !$0.shownTime.isEmpty } }
    // 群聊里别人发的、没认出昵称的消息不记：发送人不清楚，容易张冠李戴。
    messages = messages.filter { $0.fromMe || $0.sender != nil }
    return WeChatView(chat: chat, isGroup: isGroup, messages: messages)
  }

  /// 去重用的指纹：会话、发送人、内容、最近的时间分隔。来回切换会话、上下滚动都算同一条。
  /// 内容先去掉空白和标点：同一条长消息两次识别常差一个句点或空格（2026-11-10 实测）。
  public static func fingerprint(chat: String, message m: WeChatMessage) -> String {
    let key = [chat, m.fromMe ? "\u{1}me" : (m.sender ?? ""), normalized(m.text), m.shownTime].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
  }

  /// 只留文字和数字。
  public static func normalized(_ s: String) -> String {
    String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
  }

  /// 两次识别是不是同一条消息：20 字以上的规整后差别不超过 5%（至少容忍 1 个字）；短消息必须完全一致，
  /// 否则"好的""不行"这种也会被当成同一条。指纹没对上时再用它兜一层。
  public static func sameText(_ a: String, _ b: String) -> Bool {
    let x = Array(normalized(a)), y = Array(normalized(b))
    if min(x.count, y.count) < 20 { return x == y }
    let limit = max(1, max(x.count, y.count) / 20)
    if abs(x.count - y.count) > limit { return false }
    // 带宽限制的编辑距离。
    var prev = Array(0...y.count)
    for i in 1...max(x.count, 1) where !x.isEmpty {
      var cur = [i] + Array(repeating: limit + 1, count: y.count)
      let lo = max(1, i - limit), hi = min(y.count, i + limit)
      if lo <= hi {
        for j in lo...hi {
          cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
      }
      if cur.min()! > limit { return false }
      prev = cur
    }
    return x.isEmpty ? y.count <= limit : prev[y.count] <= limit
  }

  /// 把界面上的时间分隔换成具体时刻；认不出或只有日期时返回 nil（用看到的时间）。
  public static func resolve(_ shown: String, now: Date, calendar: Calendar = .current) -> Date? {
    let t = shown.trimmingCharacters(in: .whitespaces)
    guard let m = t.range(of: #"(\d{1,2})[:：](\d{2})$"#, options: .regularExpression) else { return nil }
    let parts = t[m].split(whereSeparator: { $0 == ":" || $0 == "：" }).compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    let prefix = t[..<m.lowerBound].trimmingCharacters(in: .whitespaces)
    var day = calendar.startOfDay(for: now)
    switch prefix {
    case "", "今天", "Today": break
    case "昨天", "Yesterday": day = calendar.date(byAdding: .day, value: -1, to: day)!
    case "前天": day = calendar.date(byAdding: .day, value: -2, to: day)!
    default:
      if let d = prefix.range(of: #"^(\d{1,4})[/年-](\d{1,2})(?:[/月-](\d{1,2})日?)?$"#, options: .regularExpression).map({ String(prefix[$0]) }) {
        let n = d.split(whereSeparator: { "/年月日-".contains($0) }).compactMap { Int($0) }
        var c = calendar.dateComponents([.year], from: now)
        if n.count == 3 { c.year = n[0] < 100 ? 2000 + n[0] : n[0]; c.month = n[1]; c.day = n[2] }
        else if n.count == 2 { c.month = n[0]; c.day = n[1] }
        else { return nil }
        guard let date = calendar.date(from: c) else { return nil }
        day = date
      } else if let w = weekday(prefix) {
        // 本周内的星期几：往前找最近的那天（不含今天）。
        for back in 1...7 {
          let d = calendar.date(byAdding: .day, value: -back, to: day)!
          if calendar.component(.weekday, from: d) == w { day = d; break }
        }
      } else { return nil }
    }
    guard let at = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) else { return nil }
    return at > now.addingTimeInterval(60) ? nil : at
  }

  static func weekday(_ s: String) -> Int? {
    let zh = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
    if s.hasPrefix("星期") || s.hasPrefix("周"), let ch = s.last.map(String.init) { return zh[ch] }
    let en = ["Sunday": 1, "Monday": 2, "Tuesday": 3, "Wednesday": 4, "Thursday": 5, "Friday": 6, "Saturday": 7]
    return en[s]
  }
}
