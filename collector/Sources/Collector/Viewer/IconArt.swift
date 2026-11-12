import AppKit

/// 应用图标和菜单栏共用原版的圆环、文字行和短末行；应用图标配色为铜绿、暖炭灰和暖白。
enum AppIconArt {
  static let rowColors: [UInt32] = [0x8FC7B7, 0x7DB8A9, 0x66A796, 0x4B8D7E, 0x3B7468]
  static func image(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      draw(in: rect); return true
    }
  }

  static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
  }

  static func draw(in rect: CGRect) {
    let s = rect.width
    let tile = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
    let radius = tile.width * 0.225
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.3); shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    rgb(0x181716).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    drawBackground(in: tile)
    drawMark(in: tile, glow: true)

    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
      .draw(in: CGRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    rgb(0x45413C).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.002, dy: s * 0.002), xRadius: radius, yRadius: radius)
    rim.lineWidth = s * 0.004; rim.stroke()
  }

  static func drawBackground(in rect: CGRect) {
    NSGradient(colors: [rgb(0x302E2B), rgb(0x181716)])!.draw(in: rect, angle: -90)
  }

  /// 各端导出复用同一图形，tile 是原版图标的底板范围。单色版用 alpha 轮廓由系统着色。
  static func drawMark(in tile: CGRect, monochrome: Bool = false, glow: Bool = false) {
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let r = tile.width * 0.265
    if glow {
      NSGradient(colors: [rgb(0x3B7468, 0.28), rgb(0x3B7468, 0)])!.draw(fromCenter: c, radius: 0, toCenter: c, radius: r * 1.75, options: [])
    }

    // 原版外环和内容比例不变。
    let ringR = tile.width * 0.335
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    ring.lineWidth = tile.width * 0.028
    (monochrome ? NSColor.white : rgb(0xE7E3DC)).setStroke(); ring.stroke()

    // 圆里的文字行，上浅下深。
    textDisc(center: c, radius: r, rows: 5, rowRatio: 1 / 1.42) { i, _ in
      (monochrome ? NSColor.white : rgb(rowColors[i])).setFill()
    }
  }

  /// 圆内的几行"文字"：等高的条，被圆截断；末行左对齐、右端圆头，停在圆心右侧一点。
  /// rowRatio 是行高占"行高 + 行距"的比例。setFill 在画每一行前调用，用来给行上色。
  static func textDisc(center c: CGPoint, radius r: CGFloat, rows n: Int, rowRatio: CGFloat, setFill: (Int, Int) -> Void) {
    let pitch = 2 * r / (CGFloat(n) - 1 + rowRatio)
    let h = pitch * rowRatio
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).addClip()
    for i in 0..<n {
      setFill(i, n)
      let y0 = c.y + r - CGFloat(i) * pitch - h
      if i == n - 1 {
        let end = c.x + r * 0.12
        NSBezierPath(roundedRect: CGRect(x: c.x - r, y: y0, width: end - (c.x - r), height: h), xRadius: h / 2, yRadius: h / 2).fill()
        NSBezierPath(rect: CGRect(x: c.x - r, y: y0, width: r, height: h)).fill()
      } else {
        NSBezierPath(rect: CGRect(x: c.x - r, y: y0, width: 2 * r, height: h)).fill()
      }
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  /// 构建脚本调用：把各尺寸 PNG 写进 iconset 目录，再由 iconutil 打包。
  static func writeIconset(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let px = base * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
      }
    }
  }
}

/// 菜单栏模板图：细环 + 环内内容。记录中是三行文字（和应用图标同形），暂停是两道竖条，缺权限是感叹号。
enum StatusIconArt {
  enum State { case recording, paused, warning }

  static func image(_ state: State, size: CGFloat = 18) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      draw(state, in: rect.insetBy(dx: size * 0.05, dy: size * 0.05)); return true
    }
    image.isTemplate = true
    return image
  }

  static func draw(_ state: State, in rect: CGRect) {
    let s = rect.width
    let c = CGPoint(x: rect.midX, y: rect.midY)
    NSColor.black.setStroke(); NSColor.black.setFill()
    let ringR = s * 0.42
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    ring.lineWidth = s * 0.085; ring.stroke()
    let h = s * 0.1
    switch state {
    case .recording:
      AppIconArt.textDisc(center: c, radius: s * 0.27, rows: 3, rowRatio: 0.6) { _, _ in }
    case .paused:
      for dx: CGFloat in [-1, 1] {
        let bar = CGRect(x: c.x + dx * s * 0.1 - h / 2, y: c.y - s * 0.17, width: h, height: s * 0.34)
        NSBezierPath(roundedRect: bar, xRadius: h / 2, yRadius: h / 2).fill()
      }
    case .warning:
      NSBezierPath(roundedRect: CGRect(x: c.x - h / 2, y: c.y - s * 0.02, width: h, height: s * 0.22), xRadius: h / 2, yRadius: h / 2).fill()
      NSBezierPath(ovalIn: CGRect(x: c.x - h * 0.6, y: c.y - s * 0.2, width: h * 1.2, height: h * 1.2)).fill()
    }
  }
}
