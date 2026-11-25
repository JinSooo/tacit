// 画安装盘窗口的背景：暖白底，两个图标之间一支淡暖灰箭头，告诉人把 Tacit 拖进“应用程序”。
// 用法：swift scripts/dmg-background.swift <输出目录>，输出 background.png 和 background@2x.png（dmgbuild 自动合成高清版）。
// 尺寸和图标位置与 scripts/dmg-settings.py 一致。
import AppKit

let size = NSSize(width: 640, height: 400)
let paper = NSColor(srgbRed: 0xFB / 255, green: 0xFA / 255, blue: 0xF7 / 255, alpha: 1)
let faint = NSColor(srgbRed: 0xA3 / 255, green: 0x9D / 255, blue: 0x94 / 255, alpha: 1)

func render(scale: CGFloat) -> Data {
  let pixels = NSSize(width: size.width * scale, height: size.height * scale)
  guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("无法创建位图") }
  rep.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  paper.setFill()
  NSRect(origin: .zero, size: size).fill()
  // 图标中心在 (160, 190) 和 (480, 190)（Finder 坐标从左上角量），箭头画在两者之间。
  let y = size.height - 190
  let shaft = NSBezierPath()
  shaft.move(to: NSPoint(x: 262, y: y))
  shaft.line(to: NSPoint(x: 372, y: y))
  shaft.lineWidth = 3
  shaft.lineCapStyle = .round
  faint.setStroke()
  shaft.stroke()
  let head = NSBezierPath()
  head.move(to: NSPoint(x: 362, y: y + 12))
  head.line(to: NSPoint(x: 378, y: y))
  head.line(to: NSPoint(x: 362, y: y - 12))
  head.lineWidth = 3
  head.lineCapStyle = .round
  head.lineJoinStyle = .round
  head.stroke()
  NSGraphicsContext.restoreGraphicsState()
  guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("无法编码 PNG") }
  return data
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print(out.appendingPathComponent("background.png").path)
