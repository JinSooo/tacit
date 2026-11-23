import AppKit

/// 方案 A「墨轴纪事」：左侧连续细时间轴串联三段活动，顶部此刻段以铜绿高亮，底板为暖炭灰。
enum AppIconArt {
  static let background: UInt32 = 0x211F1D
  static let backgroundTop: UInt32 = 0x2C2926
  static let backgroundBottom: UInt32 = 0x191816

  static func image(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      draw(in: rect, compact: size <= 32); return true
    }
  }

  static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((v >> 16) & 0xff) / 255,
      green: CGFloat((v >> 8) & 0xff) / 255,
      blue: CGFloat(v & 0xff) / 255,
      alpha: a
    )
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
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = s * 0.016
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    shadow.set()
    rgb(background).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    drawBackground(in: tile)
    drawMark(in: tile, compact: compact)

    // 极克制的顶部微光描边，提升 macOS Dock 中的材质层次。
    let rimInset = max(0.5, tile.width * 0.007)
    let rimRect = tile.insetBy(dx: rimInset, dy: rimInset)
    let rimPath = NSBezierPath(roundedRect: rimRect, xRadius: max(0, radius - rimInset), yRadius: max(0, radius - rimInset))
    if let cg = NSGraphicsContext.current?.cgContext,
       let grad = CGGradient(
         colorsSpace: CGColorSpaceCreateDeviceRGB(),
         colors: [rgb(0xFFFAF2, 0.22).cgColor, rgb(0xFFFAF2, 0.03).cgColor] as CFArray,
         locations: [0, 1]
       ) {
      cg.saveGState()
      cg.addPath(rimPath.cgPath)
      cg.setLineWidth(max(1, tile.width * 0.014))
      cg.replacePathWithStrokedPath()
      cg.clip()
      cg.drawLinearGradient(
        grad,
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.minY),
        options: []
      )
      cg.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  static func drawBackground(in rect: CGRect) {
    guard let cg = NSGraphicsContext.current?.cgContext,
          let grad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(backgroundTop).cgColor, rgb(backgroundBottom).cgColor] as CFArray,
            locations: [0, 1]
          ) else {
      rgb(background).setFill()
      rect.fill()
      return
    }
    cg.saveGState()
    cg.clip(to: rect)
    cg.drawLinearGradient(
      grad,
      start: CGPoint(x: rect.midX, y: rect.maxY),
      end: CGPoint(x: rect.midX, y: rect.minY),
      options: []
    )
    cg.restoreGState()
  }

  /// 各端导出复用同一图形，tile 是图标底板范围；外接框严格居中并占 tile 的 68%。
  /// 单色版用白色 alpha 轮廓由系统着色（不擦除底板，兼容预览与自适应图层）。
  static func drawMark(in tile: CGRect, monochrome: Bool = false, compact: Bool = false) {
    let s = tile.width
    let c = CGPoint(x: tile.midX, y: tile.midY)
    guard let cg = NSGraphicsContext.current?.cgContext else { return }

    if compact {
      drawCompactMark(in: tile, monochrome: monochrome)
      return
    }

    let halfSpan = s * 0.340
    let topRingR = s * 0.062
    let topRingW = s * 0.028
    let topOuterR = topRingR + topRingW / 2 // 0.076s
    let railX = c.x - halfSpan + topOuterR  // -0.264s，保证外接框左缘严格在 -halfSpan
    let railW = s * 0.028
    let railMinY = c.y - halfSpan + railW / 2
    let railMaxY = c.y + halfSpan - railW / 2

    let y1 = c.y + s * 0.195
    let y2 = c.y - s * 0.015
    let y3 = c.y - s * 0.215

    // 1. 左侧连续时间细轴：在顶环处自然断开（避免单色模式穿透空心环）
    cg.saveGState()
    let railPath = CGMutablePath()
    railPath.move(to: CGPoint(x: railX, y: railMaxY))
    railPath.addLine(to: CGPoint(x: railX, y: y1 + topOuterR - railW * 0.25))
    railPath.move(to: CGPoint(x: railX, y: y1 - topOuterR + railW * 0.25))
    railPath.addLine(to: CGPoint(x: railX, y: railMinY))
    cg.addPath(railPath)
    cg.setLineWidth(railW)
    cg.setLineCap(.round)
    if monochrome {
      cg.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
      cg.strokePath()
    } else if let grad = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [rgb(0x8FD0BF).cgColor, rgb(0xA8A197).cgColor, rgb(0x4A4540).cgColor] as CFArray,
      locations: [0, 0.55, 1]
    ) {
      cg.replacePathWithStrokedPath()
      cg.clip()
      cg.drawLinearGradient(
        grad,
        start: CGPoint(x: railX, y: railMaxY + railW / 2),
        end: CGPoint(x: railX, y: railMinY - railW / 2),
        options: []
      )
    }
    cg.restoreGState()

    let barX = c.x - s * 0.115
    let barRight = c.x + halfSpan

    // 2. 顶部「此刻」活动段：精致铜绿空心环 + 亮芯 + 铜绿渐变胶囊条
    let ringRect = CGRect(x: railX - topRingR, y: y1 - topRingR, width: topRingR * 2, height: topRingR * 2)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = topRingW
    (monochrome ? NSColor.white : rgb(0x8FD0BF)).setStroke()
    ring.stroke()

    if !monochrome {
      let coreR = s * 0.022
      rgb(0xE7F5F1).setFill()
      NSBezierPath(ovalIn: CGRect(x: railX - coreR, y: y1 - coreR, width: coreR * 2, height: coreR * 2)).fill()
    }

    let h1 = s * 0.112
    let bar1Rect = CGRect(x: barX, y: y1 - h1 / 2, width: barRight - barX, height: h1)
    let bar1Path = NSBezierPath(roundedRect: bar1Rect, xRadius: h1 / 2, yRadius: h1 / 2)
    if monochrome {
      NSColor.white.setFill()
      bar1Path.fill()
    } else if let grad = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [rgb(0x9AD4C5).cgColor, rgb(0x5CA494).cgColor] as CFArray,
      locations: [0, 1]
    ) {
      cg.saveGState()
      cg.addPath(bar1Path.cgPath)
      cg.clip()
      cg.drawLinearGradient(
        grad,
        start: CGPoint(x: bar1Rect.minX, y: bar1Rect.midY),
        end: CGPoint(x: bar1Rect.maxX, y: bar1Rect.midY),
        options: []
      )
      cg.restoreGState()
    }

    // 3. 中部「已整理」活动段：暖白节点 + 中等胶囊条
    let r2 = s * 0.048
    (monochrome ? NSColor.white : rgb(0xEEEAE3)).setFill()
    NSBezierPath(ovalIn: CGRect(x: railX - r2, y: y2 - r2, width: r2 * 2, height: r2 * 2)).fill()

    let h2 = s * 0.104
    let bar2Rect = CGRect(x: barX, y: y2 - h2 / 2, width: (barRight - barX) * 0.78, height: h2)
    (monochrome ? NSColor.white.withAlphaComponent(0.9) : rgb(0xE7E3DC, 0.92)).setFill()
    NSBezierPath(roundedRect: bar2Rect, xRadius: h2 / 2, yRadius: h2 / 2).fill()

    // 4. 底部「更早」活动段：暖灰节点 + 短胶囊条
    let r3 = s * 0.040
    (monochrome ? NSColor.white.withAlphaComponent(0.75) : rgb(0x8B847B)).setFill()
    NSBezierPath(ovalIn: CGRect(x: railX - r3, y: y3 - r3, width: r3 * 2, height: r3 * 2)).fill()

    let h3 = s * 0.096
    let bar3Rect = CGRect(x: barX, y: y3 - h3 / 2, width: (barRight - barX) * 0.52, height: h3)
    (monochrome ? NSColor.white.withAlphaComponent(0.65) : rgb(0x6D6760)).setFill()
    NSBezierPath(roundedRect: bar3Rect, xRadius: h3 / 2, yRadius: h3 / 2).fill()
  }

  /// 小尺寸（16px / 32px）采用两段疏版墨轴，保证低分辨率下依然清晰锐利。
  private static func drawCompactMark(in tile: CGRect, monochrome: Bool) {
    let s = tile.width
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let halfSpan = s * 0.345
    let railX = c.x - s * 0.24
    let railW = max(1, s * 0.07)

    let rail = NSBezierPath()
    rail.move(to: CGPoint(x: railX, y: c.y + halfSpan - railW / 2))
    rail.line(to: CGPoint(x: railX, y: c.y - halfSpan + railW / 2))
    rail.lineWidth = railW
    rail.lineCapStyle = .round
    (monochrome ? NSColor.white.withAlphaComponent(0.75) : rgb(0x8E877E)).setStroke()
    rail.stroke()

    let barX = c.x - s * 0.06
    let barRight = c.x + halfSpan

    let y1 = c.y + s * 0.145
    let r1 = s * 0.105
    (monochrome ? NSColor.white : rgb(0x93CBBD)).setFill()
    NSBezierPath(ovalIn: CGRect(x: railX - r1, y: y1 - r1, width: r1 * 2, height: r1 * 2)).fill()
    let h1 = s * 0.175
    NSBezierPath(roundedRect: CGRect(x: barX, y: y1 - h1 / 2, width: barRight - barX, height: h1), xRadius: h1 / 2, yRadius: h1 / 2).fill()

    let y2 = c.y - s * 0.155
    let r2 = s * 0.088
    (monochrome ? NSColor.white.withAlphaComponent(0.85) : rgb(0xE7E3DC)).setFill()
    NSBezierPath(ovalIn: CGRect(x: railX - r2, y: y2 - r2, width: r2 * 2, height: r2 * 2)).fill()
    let h2 = s * 0.155
    NSBezierPath(roundedRect: CGRect(x: barX, y: y2 - h2 / 2, width: (barRight - barX) * 0.68, height: h2), xRadius: h2 / 2, yRadius: h2 / 2).fill()
  }

  /// 构建脚本调用：把各尺寸 PNG 写进 iconset 目录，再由 iconutil 打包。
  static func writeIconset(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let px = base * scale
        guard let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGRect(x: 0, y: 0, width: px, height: px), compact: base <= 32)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
      }
    }
  }
}

/// 菜单栏与通知单色模板图：正常记录为无框三段墨轴；暂停与异常保留圆环语义以便一眼区分。
enum StatusIconArt {
  enum State { case recording, paused, warning }

  static func image(_ state: State, size: CGFloat = 18) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      draw(state, in: rect.insetBy(dx: size * 0.05, dy: size * 0.05)); return true
    }
    image.isTemplate = true
    return image
  }

  static func draw(_ state: State, in rect: CGRect, radiusRatio: CGFloat = 0.27) {
    _ = radiusRatio
    let s = rect.width
    let c = CGPoint(x: rect.midX, y: rect.midY)
    NSColor.black.setStroke()
    NSColor.black.setFill()

    switch state {
    case .recording:
      // 左侧竖轴 + 三段由长到短的活动胶囊，无外环干扰，18px 轮廓鲜明。
      let railX = rect.minX + s * 0.22
      let railW = max(1.2, s * 0.095)
      let rail = NSBezierPath()
      rail.move(to: CGPoint(x: railX, y: rect.maxY - s * 0.11))
      rail.line(to: CGPoint(x: railX, y: rect.minY + s * 0.11))
      rail.lineWidth = railW
      rail.lineCapStyle = .round
      rail.stroke()

      let barX = rect.minX + s * 0.45
      let rows: [(yFrac: CGFloat, dotR: CGFloat, barW: CGFloat, barH: CGFloat)] = [
        (0.75, 0.120, 0.45, 0.160),
        (0.49, 0.092, 0.33, 0.142),
        (0.24, 0.078, 0.20, 0.128),
      ]
      for row in rows {
        let y = rect.minY + s * row.yFrac
        let r = s * row.dotR
        NSBezierPath(ovalIn: CGRect(x: railX - r, y: y - r, width: r * 2, height: r * 2)).fill()
        let h = s * row.barH
        let w = s * row.barW
        NSBezierPath(roundedRect: CGRect(x: barX, y: y - h / 2, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
      }

    case .paused:
      let ringR = s * 0.42
      let ring = NSBezierPath(ovalIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
      ring.lineWidth = s * 0.065
      ring.stroke()
      let h = s * 0.105
      for dx: CGFloat in [-1, 1] {
        let bar = CGRect(x: c.x + dx * s * 0.105 - h / 2, y: c.y - s * 0.17, width: h, height: s * 0.34)
        NSBezierPath(roundedRect: bar, xRadius: h / 2, yRadius: h / 2).fill()
      }

    case .warning:
      let ringR = s * 0.42
      let ring = NSBezierPath(ovalIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
      ring.lineWidth = s * 0.065
      ring.stroke()
      let h = s * 0.105
      NSBezierPath(roundedRect: CGRect(x: c.x - h / 2, y: c.y - s * 0.02, width: h, height: s * 0.22), xRadius: h / 2, yRadius: h / 2).fill()
      NSBezierPath(ovalIn: CGRect(x: c.x - h * 0.6, y: c.y - s * 0.2, width: h * 1.2, height: h * 1.2)).fill()
    }
  }
}

private extension NSBezierPath {
  var cgPath: CGPath {
    let path = CGMutablePath()
    var pts = [NSPoint](repeating: .zero, count: 3)
    for i in 0..<elementCount {
      switch element(at: i, associatedPoints: &pts) {
      case .moveTo: path.move(to: pts[0])
      case .lineTo: path.addLine(to: pts[0])
      case .curveTo, .cubicCurveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
      case .quadraticCurveTo: path.addQuadCurve(to: pts[1], control: pts[0])
      case .closePath: path.closeSubpath()
      @unknown default: break
      }
    }
    return path
  }
}
