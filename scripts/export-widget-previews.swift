import AppKit
import SwiftUI
import WidgetKit

@main enum ExportWidgetPreviews {
  @MainActor
  static func main() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let exportIndividual = CommandLine.arguments.contains("--individual")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared

    // 虚构项目「晴天记账」/ "Sunledger"。固定日期是为了让示意图可复现。
    let date = time(18, 30)
    let zhSnapshot = WidgetSnapshot(
      day: TimelineDay.key(date),
      summary: "上午在「晴天记账」修好月度报表的汇总错误，和设计师小林定下首页卡片样式；下午和 Claude 定了导出格式，傍晚读完 SwiftData 迁移文档。",
      segments: [
        .init(start: time(17, 40), end: time(18, 25), title: "读 SwiftData 迁移文档",
              description: "弄清轻量迁移和自定义迁移的分界"),
        .init(start: time(15, 10), end: time(16, 50), title: "设计导出功能的数据格式",
              description: "定为 CSV 加一份 JSON 元数据，金额统一存分"),
        .init(start: time(14, 0), end: time(14, 45), title: "和小林确认首页卡片样式",
              description: "保留圆角卡片，去掉渐变，周五前出终稿"),
        .init(start: time(11, 20), end: time(12, 10), title: "调整首页卡片设计稿",
              description: "对比三版间距，选了留白更大的一版"),
        .init(start: time(9, 30), end: time(11, 5), title: "修正月度报表汇总",
              description: "退款回到原来的月份，月末余额与账单对齐"),
      ],
      language: .zh)
    let enSnapshot = WidgetSnapshot(
      day: TimelineDay.key(date),
      summary: "Worked on Sunledger: fixed CSV date parsing for UK banks and shipped budget rollover; deleted categories are still open. Agreed with Sam to cut onboarding to one screen. Nora asked for rent splitting.",
      segments: [
        .init(start: time(15, 10), end: time(16, 0), title: "Call with Nora (beta user)",
              description: "Splits rent with roommates and wants who-owes-whom tracking"),
        .init(start: time(13, 30), end: time(14, 55), title: "Built monthly budget rollover",
              description: "Shipped rollover rules; deleted categories still open"),
        .init(start: time(10, 45), end: time(11, 20), title: "Onboarding review with Sam",
              description: "Cut the four-step onboarding tour down to one screen"),
        .init(start: time(9, 20), end: time(10, 25), title: "Fixed UK bank CSV import",
              description: "Added date-format detection for DD/MM exports"),
      ],
      language: .en)

    for (prefix, snapshot) in [("widget", zhSnapshot), ("widget-en", enSnapshot)] {
      for (name, scheme, appearanceName) in [
        ("light", ColorScheme.light, NSAppearance.Name.aqua),
        ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
      ] {
        let appearance = NSAppearance(named: appearanceName)!
        let large = widget(.systemLarge, height: 344, date: date, snapshot: snapshot)
        let medium = widget(.systemMedium, height: 160, date: date, snapshot: snapshot)
        let pair = HStack(alignment: .top, spacing: 28) {
          large
          medium
        }
        .padding(32)
        try write(pair, scheme: scheme, appearance: appearance, to: output.appendingPathComponent("\(prefix)-\(name).png"))
        if exportIndividual {
          try write(large, scheme: scheme, appearance: appearance, to: output.appendingPathComponent("\(prefix)-large-\(name).png"))
          try write(medium, scheme: scheme, appearance: appearance, to: output.appendingPathComponent("\(prefix)-medium-\(name).png"))
        }
      }
    }
  }

  private static func time(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: hour, minute: minute))!
  }

  private static func widget(_ family: WidgetFamily, height: CGFloat, date: Date, snapshot: WidgetSnapshot) -> some View {
    DayWidgetView(family: family, date: date, snapshot: snapshot).content
      .frame(width: 344, height: height)
      .background(Palette.paper)
      .clipShape(RoundedRectangle(cornerRadius: 22))
  }

  @MainActor
  private static func write<V: View>(
    _ view: V, scheme: ColorScheme, appearance: NSAppearance, to file: URL
  ) throws {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
    renderer.scale = 2
    var image: CGImage?
    appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
    guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file])
    }
    try png.write(to: file, options: .atomic)
    print(file.path)
  }
}
