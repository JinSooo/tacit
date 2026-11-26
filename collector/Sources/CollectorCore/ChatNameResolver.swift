import Foundation

/// 截图识字常把同一个聊天名读错一两个字（“童文科”读成“重文科”“菫文科”），每种读法都会被当成一个新聊天，
/// 去重指纹又带着聊天名，同一条消息就被存好几遍（2026-11-26 真实数据：一个聊天 14 天里名字 10 分钟内来回变了 133 次）。
/// 同一条消息（是不是自己发的、规整后的内容、上方的时间分隔都相同）先后出现在两个只差一两个字的名字下，就认定是同一个聊天，
/// 统一用读到次数最多的写法。只在内存里，不落盘；重启后从头数，跨重启的旧写法由中枢按同样规则合并。
public struct ChatNameResolver {
  private var clusterOfName: [String: Int] = [:]
  /// 每组里各写法读到的次数，和第一次读到的先后（次数相同时用先读到的）。
  private var votes: [[String: Int]] = []
  private var spellings: [[String]] = []
  private var owner: [String: Int] = [:]
  private var ownerOrder: [String] = []
  private static let ownerLimit = 5000

  public init() {}

  /// 返回这一屏该用的聊天名，以及这个聊天在本次运行里不变的编号（名字的多数读法变了，编号也不变，给本地去重用）。
  public mutating func resolve(_ view: WeChatView) -> (chat: String, cluster: Int) {
    let key = ChatNames.key(view.chat)
    let contents = view.messages.map(Self.content)
    var cluster = clusterOfName[key]
    var hits: [Int: (count: Int, strong: Bool)] = [:]
    // 没有时间分隔的消息不能当作“同一条”的证据：不同聊天里的同一句话太容易撞上。
    for (content, message) in zip(contents, view.messages) where !message.shownTime.isEmpty {
      guard let other = owner[content].map({ find($0) }), other != cluster else { continue }
      let strong = WeChatLayout.normalized(message.text).count >= 4
      hits[other] = ((hits[other]?.count ?? 0) + 1, (hits[other]?.strong ?? false) || strong)
    }
    for (other, hit) in hits.sorted(by: { $0.key < $1.key }) where hit.strong || hit.count >= 2 {
      guard spellings[other].contains(where: { Self.near(ChatNames.key($0), key) }) else { continue }
      if let current = cluster { if current != other { merge(other, into: current) } } else { cluster = other }
    }
    let id = cluster ?? { votes.append([:]); spellings.append([]); return votes.count - 1 }()
    clusterOfName[key] = id
    if votes[id][view.chat] == nil { spellings[id].append(view.chat) }
    votes[id][view.chat, default: 0] += 1
    for (content, message) in zip(contents, view.messages) where !message.shownTime.isEmpty {
      if owner[content] == nil { ownerOrder.append(content) }
      owner[content] = id
    }
    if ownerOrder.count > Self.ownerLimit {
      for old in ownerOrder.prefix(1000) { owner.removeValue(forKey: old) }
      ownerOrder.removeFirst(1000)
    }
    let best = spellings[id].max { votes[id][$0]! < votes[id][$1]! || (votes[id][$0]! == votes[id][$1]! && spellings[id].firstIndex(of: $0)! > spellings[id].firstIndex(of: $1)!) }
    return (best ?? view.chat, id)
  }

  /// 合并后旧编号只留一个指向，查的时候顺着找到现在的组。
  private var mergedInto: [Int: Int] = [:]
  private func find(_ id: Int) -> Int {
    var id = id
    while let next = mergedInto[id] { id = next }
    return id
  }

  private mutating func merge(_ other: Int, into target: Int) {
    for spelling in spellings[other] where votes[target][spelling] == nil { spellings[target].append(spelling) }
    for (spelling, n) in votes[other] { votes[target][spelling, default: 0] += n }
    for (name, id) in clusterOfName where id == other { clusterOfName[name] = target }
    votes[other] = [:]; spellings[other] = []
    mergedInto[other] = target
  }

  static func content(_ m: WeChatMessage) -> String {
    [m.fromMe ? "1" : "0", WeChatLayout.normalized(m.text), m.shownTime].joined(separator: "\u{0}")
  }

  /// 两个名字（已去空白）只差一个字；6 个字以上允许差两个。单字名、只差数字的（“项目1群”“项目2群”）不算。
  public static func near(_ a: String, _ b: String) -> Bool {
    let x = Array(a), y = Array(b)
    guard min(x.count, y.count) >= 2, a != b else { return a == b }
    let digits = CharacterSet.decimalDigits
    func letters(_ s: String) -> String { String(s.unicodeScalars.filter { !digits.contains($0) }) }
    if letters(a) == letters(b) { return false }
    let limit = max(x.count, y.count) >= 6 ? 2 : 1
    if abs(x.count - y.count) > limit { return false }
    var prev = Array(0...y.count)
    for i in 1...x.count {
      var cur = [i] + Array(repeating: 0, count: y.count)
      for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
      prev = cur
    }
    return prev[y.count] <= limit
  }
}
