import AppKit

func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }

// 用户报告的三行退化：检查实际导出像素，而非源码中的行数常量。
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icons/generated/menubar")
for size in [36, 54] {
  let url = root.appendingPathComponent("recording-\(size).png")
  guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data) else {
    fail("缺少菜单栏图标：\(size)px")
  }
  // 中轴穿过短末行；两个外环交点加上五行，应有七段互不相连的实心像素。
  var runs = 0, previous = false
  for y in 0..<image.pixelsHigh {
    let filled = (image.colorAt(x: size / 2 - 1, y: y)?.alphaComponent ?? 0) >= 0.5
    if filled && !previous { runs += 1 }
    previous = filled
  }
  guard runs == 7 else { fail("菜单栏 \(size)px 应为圆环加五行，实际检测到 \(runs - 2) 行") }
}
print("Mac 菜单栏五行图标：36 / 54px 像素回归通过。")
