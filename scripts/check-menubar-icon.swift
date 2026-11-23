import AppKit

func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }

// 检查方案 A「墨轴纪事」菜单栏图标的实际渲染像素：左侧竖轴连贯、右侧三段活动条互不粘连。
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icons/generated/menubar")
for size in [18, 36, 54] {
  let url = root.appendingPathComponent("recording-\(size).png")
  guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data) else {
    fail("缺少菜单栏图标：\(size)px")
  }
  // StatusIconArt.draw 有 5% 外边距，竖轴中心位于 0.05 + 0.90 * 0.22 = 24.8% 处。
  let railX = Int(floor(Double(size) * 0.248))
  let barX = Int(floor(Double(size) * 0.56))

  var railRuns = 0, railPrev = false
  for y in 0..<image.pixelsHigh {
    let filled = (image.colorAt(x: railX, y: y)?.alphaComponent ?? 0) >= 0.45
    if filled && !railPrev { railRuns += 1 }
    railPrev = filled
  }
  guard railRuns == 1 else { fail("菜单栏 \(size)px 左侧时间轴应连续不断裂，实际检测到 \(railRuns) 段") }

  var barRuns = 0, barPrev = false
  for y in 0..<image.pixelsHigh {
    let filled = (image.colorAt(x: barX, y: y)?.alphaComponent ?? 0) >= 0.45
    if filled && !barPrev { barRuns += 1 }
    barPrev = filled
  }
  guard barRuns == 3 else { fail("菜单栏 \(size)px 右侧应有 3 段独立活动条，实际检测到 \(barRuns) 段") }
}
print("Mac 菜单栏墨轴图标：18 / 36 / 54px 像素回归通过。")
