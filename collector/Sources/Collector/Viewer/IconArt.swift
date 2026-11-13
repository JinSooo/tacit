import AppKit

/// 应用图标和菜单栏共用原版的圆环、文字行和短末行；应用图标配色为铜绿、暖炭灰和暖白。
enum AppIconArt {
  static let rowColors: [UInt32] = [0x93CBBD, 0x81BFB0, 0x6BAE9F, 0x599D8E, 0x4B8D7E]
  static let background: UInt32 = 0x211F1D
  static func image(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      draw(in: rect, compact: size <= 32); return true
    }
  }

  static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
  }

  static func draw(in rect: CGRect) {
    draw(in: rect, compact: false)
  }

  static func draw(in rect: CGRect, compact: Bool) {
    let s = rect.width
    let tile = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
    let radius = tile.width * 0.225
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.16); shadow.shadowBlurRadius = s * 0.015
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    shadow.set()
    rgb(background).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    drawBackground(in: tile)
    drawMark(in: tile, compact: compact)
    NSGraphicsContext.restoreGraphicsState()
  }

  static func drawBackground(in rect: CGRect) {
    rgb(background).setFill(); rect.fill()
  }

  /// 各端导出复用同一图形，tile 是原版图标的底板范围。单色版用 alpha 轮廓由系统着色。
  static func drawMark(in tile: CGRect, monochrome: Bool = false, compact: Bool = false) {
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let r = tile.width * 0.265

    // 原版外环和内容比例不变。
    let ringR = tile.width * 0.335
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    ring.lineWidth = tile.width * (compact ? 0.045 : 0.024)
    (monochrome ? NSColor.white : rgb(0xE7E3DC)).setStroke(); ring.stroke()

    // 圆里的文字行，上浅下深。
    textDisc(center: c, radius: r, rows: compact ? 3 : 5, rowRatio: compact ? 0.6 : 1 / 1.42) { i, _ in
      (monochrome ? NSColor.white : rgb(rowColors[compact ? i * 2 : i])).setFill()
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
        // 简化按逻辑尺寸选择，1× / 2× 保持同样的行数。
        draw(in: CGRect(x: 0, y: 0, width: px, height: px), compact: base <= 32)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
      }
    }
  }
}

/// 菜单栏模板图：细环 + 环内内容。记录中是五行文字与短末行（按选定配套图），暂停是两道竖条，缺权限是感叹号。
enum StatusIconArt {
  enum State { case recording, paused, warning }

  static func image(_ state: State, size: CGFloat = 18) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      draw(state, in: rect.insetBy(dx: size * 0.05, dy: size * 0.05)); return true
    }
    image.isTemplate = true
    return image
  }

  static func draw(_ state: State, in rect: CGRect, textRows: Int = 5) {
    let s = rect.width
    let c = CGPoint(x: rect.midX, y: rect.midY)
    NSColor.black.setStroke(); NSColor.black.setFill()
    let ringR = s * 0.42
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    ring.lineWidth = s * 0.06; ring.stroke()
    let h = s * 0.1
    switch state {
    case .recording:
      AppIconArt.textDisc(center: c, radius: s * 0.32, rows: textRows, rowRatio: textRows == 3 ? 0.6 : 1 / 1.42) { _, _ in }
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
