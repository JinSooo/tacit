import Foundation
import Testing
@testable import CollectorCore

// 坐标照 2026-11-10 真实截图实测的版面（深色模式，窗口 1053×770），文字全是合成的。
private let W = 1053.0, H = 770.0
private func line(_ text: String, _ minX: Double, _ maxX: Double, _ y: Double, h: Double = 15) -> OCRLine {
  OCRLine(text, minX: minX, maxX: maxX, y: y, height: h)
}
/// 会话列表：名字在 x≈118，时间列右边缘对齐在 279–281。
private let sidebar: [OCRLine] = [
  line("Search", 98, 139, 23, h: 11),
  line("合成会话甲", 118, 202, 69), line("12:38", 251, 279, 70, h: 10),
  line("交开投合成预览", 118, 272, 89),
  line("合成会话乙", 117, 172, 133), line("12:18", 249, 279, 135, h: 11),
  line("合成会话丙", 118, 196, 219), line("Yesterday 19:22", 202, 279, 265, h: 11),
  line("合成会话丁", 118, 176, 349), line("11/03", 249, 279, 395, h: 11),
]

@Test func weChatGroupChatSplitsIntoMessagesWithSendersAndSkipsSidebarQuoteDraftAndImageText() throws {
  let lines = sidebar + [
    line("合成项目群（19）", 304, 502, 19, h: 18),
    line("合成甲", 360, 409, 52, h: 14), line("上面这条在第一个时间分隔之前", 370, 523, 78),
    line("17:00", 652, 686, 210, h: 14),
    line("合成乙", 358, 384, 246, h: 14), line("第一行", 370, 473, 277), line("第二行", 370, 470, 296),
    line("合成甲", 357, 395, 404, h: 16), line("工具栏收起后和菜单栏融合", 370, 450, 435),
    line("合成乙：被引用的内容", 361, 537, 466, h: 20),
    line("我发的消息", 880, 966, 493, h: 17),
    line("图里的小字", 753, 923, 520, h: 8),
    line("输入框草稿", 306, 504, 592, h: 18),
    line("Send", 987, 1018, 731, h: 13),
  ]
  let view = try #require(WeChatLayout.parse(lines, width: W, height: H))
  #expect(view.chat == "合成项目群")
  #expect(view.isGroup)
  #expect(view.messages == [
    WeChatMessage(sender: "合成乙", fromMe: false, text: "第一行\n第二行", shownTime: "17:00"),
    WeChatMessage(sender: "合成甲", fromMe: false, text: "工具栏收起后和菜单栏融合", shownTime: "17:00"),
    WeChatMessage(sender: nil, fromMe: true, text: "我发的消息", shownTime: "17:00"),
  ])
  // 通用 OCR 去掉会话列表：这次归错就是因为列表里别的群的预览（"交开投…"）混进了正文。
  #expect(!WeChatLayout.chatAreaLines(lines, width: W).contains { $0.text.contains("交开投") })
  #expect(WeChatLayout.chatAreaLines(lines, width: W).contains { $0.text == "工具栏收起后和菜单栏融合" })
}

@Test func weChatDirectChatUsesChatNameAsSenderAndWideWindowKeepsOffsets() throws {
  let wide = 1728.0
  let lines = [
    line("合成同事", 305, 363, 18, h: 18),
    line("Yesterday 15:33", 957, 1060, 115, h: 15),
    line("对方说的话", 372, 618, 241, h: 20),
    line("我回的很长一段话", 1027, 1640, 339, h: 18),
  ]
  let view = try #require(WeChatLayout.parse(lines, width: wide, height: 1084))
  #expect(view.chat == "合成同事")
  #expect(!view.isGroup)
  #expect(view.messages == [
    WeChatMessage(sender: "合成同事", fromMe: false, text: "对方说的话", shownTime: "Yesterday 15:33"),
    WeChatMessage(sender: nil, fromMe: true, text: "我回的很长一段话", shownTime: "Yesterday 15:33"),
  ])
}

@Test func weChatNotAChatViewAndFingerprintStability() {
  #expect(WeChatLayout.parse(sidebar, width: W, height: H) == nil)
  let m = WeChatMessage(sender: "合成乙", fromMe: false, text: "好的", shownTime: "17:00")
  #expect(WeChatLayout.fingerprint(chat: "群", message: m) == WeChatLayout.fingerprint(chat: "群", message: m))
  #expect(WeChatLayout.fingerprint(chat: "群", message: m) != WeChatLayout.fingerprint(chat: "别的群", message: m))
  var mine = m; mine.fromMe = true; mine.sender = nil
  #expect(WeChatLayout.fingerprint(chat: "群", message: m) != WeChatLayout.fingerprint(chat: "群", message: mine))
}

@Test func weChatShownTimeResolvesToDates() {
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 16, minute: 0))! // 星期二
  func at(_ d: Int, _ h: Int, _ m: Int, month: Int = 11) -> Date { cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))! }
  #expect(WeChatLayout.resolve("15:33", now: now, calendar: cal) == at(10, 15, 33))
  #expect(WeChatLayout.resolve("昨天 15:33", now: now, calendar: cal) == at(9, 15, 33))
  #expect(WeChatLayout.resolve("Yesterday 12:17", now: now, calendar: cal) == at(9, 12, 17))
  #expect(WeChatLayout.resolve("星期日 10:00", now: now, calendar: cal) == at(8, 10, 0))
  #expect(WeChatLayout.resolve("11/03 09:57", now: now, calendar: cal) == at(3, 9, 57))
  #expect(WeChatLayout.resolve("2025/12/31 23:00", now: now, calendar: cal) == cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23)))
  #expect(WeChatLayout.resolve("17:30", now: now, calendar: cal) == nil)   // 还没到的时刻
  #expect(WeChatLayout.resolve("11/03", now: now, calendar: cal) == nil)   // 只有日期
}

// 回归：同一条长消息两次识别差一个字，指纹不同，入库了两次（2026-11-10 真机）。
@Test func weChatOCRJitterIsTreatedAsTheSameMessage() {
  let a = WeChatMessage(sender: "合成乙", fromMe: false, text: "合成的一段长消息，内容大约一百字。第二行 v3.6.beta", shownTime: "11:11")
  var b = a; b.text = "合成的一段长消息，内容大约一百字第二行 v3.6.beta"
  #expect(WeChatLayout.fingerprint(chat: "群", message: a) == WeChatLayout.fingerprint(chat: "群", message: b))
  let long = String(repeating: "合成文字", count: 25)
  #expect(WeChatLayout.sameText(long + "字", long + "子"))
  #expect(WeChatLayout.sameText(long, long + "多"))
  #expect(!WeChatLayout.sameText("好的", "不行"))
  #expect(!WeChatLayout.sameText(long, String(repeating: "别的内容", count: 25)))
}

@Test func weChatChatNameNormalizationAndComparison() {
  for (raw, expected) in [(" C 王家琪 \n", "C王家琪"), ("C 童文科", "C童文科"), ("中 交 三航局 星云测试", "中交三航局星云测试"), ("群 123 A", "群123 A"), (" File   Transfer ", "File Transfer"), ("C王家琪", "C王家琪")] {
    #expect(ChatNames.normalize(raw) == expected)
  }
  #expect(ChatNames.key("C 王家琪") == ChatNames.key("C王家琪"))
  #expect(ChatNames.key("File Transfer") == ChatNames.key("FileTransfer"))
}

@Test func weChatRejectsNoiseWithoutFallingBackToAnotherTitle() throws {
  let rejected = ["←品", "←→品", "●••", "●", "→群", "‹群", "›群", "<群", ">群", "", "  "]
  for name in rejected {
    #expect(!ChatNames.isValid(name))
    let lines = [line(name, 304, 400, 19, h: 18), line("真实会话", 500, 600, 19, h: 18), line("正文", 370, 470, 100)]
    #expect(WeChatLayout.parse(lines, width: W, height: H) == nil)
  }
  for name in ["File Transfer", "中交三航局星云测试", "C王家琪"] {
    #expect(ChatNames.isValid(name))
    let view = try #require(WeChatLayout.parse([line(name, 304, 500, 19, h: 18), line("正文", 370, 470, 100)], width: W, height: H))
    #expect(view.chat == name)
    #expect(view.messages.count == 1)
  }
  // 单字标题多半是图标被认成了字：会话列表里也有同名一行才算聊天（2026-11-26）。
  for name in ["図", "群"] {
    #expect(ChatNames.isValid(name))
    #expect(WeChatLayout.parse([line(name, 304, 500, 19, h: 18), line("正文", 370, 470, 100)], width: W, height: H) == nil)
    #expect(WeChatLayout.parse(sidebar + [line(name, 304, 500, 19, h: 18), line("正文", 370, 470, 100)], width: W, height: H) == nil)
    let listed = sidebar + [line(name, 118, 140, 433), line("12:01", 251, 279, 434, h: 10)]
    let view = try #require(WeChatLayout.parse(listed + [line(name, 304, 500, 19, h: 18), line("正文", 370, 470, 100)], width: W, height: H))
    #expect(view.chat == name)
  }
  let view = try #require(WeChatLayout.parse([line("C 王家琪（19）", 304, 600, 19, h: 18)], width: W, height: H))
  #expect(view.chat == "C王家琪")
  #expect(view.isGroup)
}

@Test func weChatFilePreviewsAreNotChats() {
  for name in ["2026111116361055124.pdf", "金凡-简历-定稿V2-20261026（1）.pdf", "报告.PDF", "表格.xlsx", "归档.ZIP", "照片.JPEG", "视频.MOV", "文档.docx", "演示.pptx", "说明.txt", "归档.rar", "照片.png", "照片.jpg", "视频.mp4", "旧文档.doc", "旧表格.xls", "旧演示.ppt"] {
    #expect(ChatNames.isFilePreview(name))
    #expect(!ChatNames.isValid(name))
    #expect(WeChatLayout.parse([line(name, 304, 800, 19, h: 18), line("文件内容", 370, 470, 100)], width: W, height: H) == nil)
  }
  for name in ["File Transfer", "中交三航局星云测试", "C王家琪", "pdf讨论群", "文档.pdf讨论"] {
    #expect(!ChatNames.isFilePreview(name))
  }
}

@Test func weChatReadsTheMainWindowAndSkipsViewers() {
  #expect(WeChatLayout.windowRank("Weixin") == 0)
  #expect(WeChatLayout.windowRank("微信") == 0)
  #expect(WeChatLayout.windowRank("Photos and Videos") == nil)
  #expect(WeChatLayout.windowRank("报告.pdf") == nil)
  #expect(WeChatLayout.windowRank("合成会话甲") == 1)
}

private func view(_ chat: String, _ texts: [String], time: String = "17:00", group: Bool = false) -> WeChatView {
  WeChatView(chat: chat, isGroup: group, messages: texts.map { WeChatMessage(sender: group ? "合成甲" : chat, fromMe: false, text: $0, shownTime: time) })
}

@Test func misreadChatNamesSharingAMessageBecomeOneChat() {
  var names = ChatNameResolver()
  // 2026-11-26 真实情况的合成版：同一屏消息先后被读成三种名字。
  let first = names.resolve(view("C合成文科", ["展板明天上午送到", "好的"]))
  #expect(first.chat == "C合成文科")
  let misread = names.resolve(view("C合戊文科", ["展板明天上午送到", "好的"]))
  #expect(misread == first)
  _ = names.resolve(view("C合成文科", ["展板明天上午送到"]))
  #expect(names.resolve(view("C合戊文料", ["展板明天上午送到"])) == first)
  // 多数读法换了时，编号不变，名字跟着多数走。
  for _ in 0..<5 { _ = names.resolve(view("C合戊文科", ["展板明天上午送到"])) }
  #expect(names.resolve(view("C合成文科", ["展板明天上午送到"])) == ("C合戊文科", first.cluster))
}

@Test func differentChatsAreNotMergedOnNamesOrShortMessagesAlone() {
  var names = ChatNameResolver()
  let a = names.resolve(view("合成张伟群", ["收到"]))
  // 名字只差一个字，但只共有一条很短的消息：不能认定是同一个聊天。
  let b = names.resolve(view("合成张玮群", ["收到"]))
  #expect(a.cluster != b.cluster)
  // 共有一条实在的消息，但名字差得远：也不合并。
  let c = names.resolve(view("合成项目甲", ["展板明天上午送到"]))
  let d = names.resolve(view("另一个讨论组", ["展板明天上午送到"]))
  #expect(c.cluster != d.cluster)
  #expect(!ChatNameResolver.near("図", "国"))
  #expect(!ChatNameResolver.near("合成项目1群", "合成项目10群"))
  // 没有时间分隔的同一句话不算证据。
  let e = names.resolve(view("合成甲组", ["展板明天上午送到"], time: ""))
  let f = names.resolve(view("合成乙组", ["展板明天上午送到"], time: ""))
  #expect(e.cluster != f.cluster)
  #expect(ChatNameResolver.near("AlTeam", "AITeam"))
  #expect(ChatNameResolver.near("定制开发—桥梁健康检测系统", "定制开发一桥梁健康检测系统"))
}
