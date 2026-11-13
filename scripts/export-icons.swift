import AppKit

/// 只编译 IconArt.swift，不启动采集端、不读取用户数据或申请权限。
@main
struct ExportIcons {
  static var root: URL!
  static var pngCount = 0

  static func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  static func text(_ content: String, _ path: String) throws {
    try write(Data(content.utf8), path)
  }

  @discardableResult
  static func png(_ path: String, size: Int, height: Int? = nil, draw: (CGRect) -> Void) throws -> Data {
    let height = height ?? size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { throw failure("无法创建位图: \(path)") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: height))
    draw(CGRect(x: 0, y: 0, width: size, height: height))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]),
      let decoded = NSBitmapImageRep(data: data), decoded.pixelsWide == size,
      decoded.pixelsHigh == height else { throw failure("PNG 编码验证失败: \(path)") }
    try write(data, path)
    pngCount += 1
    return data
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "IconExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  static func fullBleed(_ rect: CGRect) {
    AppIconArt.drawBackground(in: rect)
    AppIconArt.drawMark(in: rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1))
  }

  static func androidMark(_ layer: CGRect, monochrome: Bool = false) {
    // 108dp 图层裁到桌面可见区域后，圆环仍应有清晰的深色留白。
    // 圆环外径约 49dp；彩色、单色和预览使用同一比例。
    AppIconArt.drawMark(in: layer.insetBy(dx: layer.width * 0.175, dy: layer.height * 0.175),
                       monochrome: monochrome)
  }

  static func status(_ state: StatusIconArt.State, in rect: CGRect, white: Bool = false, radiusRatio: CGFloat = 0.27) {
    StatusIconArt.draw(state, in: rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05), radiusRatio: radiusRatio)
    if white {
      NSColor.white.setFill()
      NSGraphicsContext.current!.cgContext.setBlendMode(.sourceIn)
      rect.fill()
      NSGraphicsContext.current!.cgContext.setBlendMode(.normal)
    }
  }

  static func ico(_ images: [(Int, Data)]) -> Data {
    var data = Data()
    func u16(_ n: Int) { data.append(UInt8(n & 255)); data.append(UInt8((n >> 8) & 255)) }
    func u32(_ n: Int) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((n >> shift) & 255)) } }
    u16(0); u16(1); u16(images.count)
    var offset = 6 + 16 * images.count
    for (size, png) in images {
      data.append(UInt8(size == 256 ? 0 : size)); data.append(UInt8(size == 256 ? 0 : size))
      data.append(0); data.append(0); u16(1); u16(32); u32(png.count); u32(offset)
      offset += png.count
    }
    for (_, png) in images { data.append(png) }
    return data
  }

  static func main() throws {
    guard CommandLine.arguments.count == 2 else { throw failure("需要输出根目录") }
    root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let base = "assets/icons/generated"
    try png("\(base)/master-1024.png", size: 1024, draw: AppIconArt.draw)
    for size in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png("\(base)/macos/AppIcon.iconset/icon_\(size)x\(size)\(suffix).png", size: size * scale) { rect in
          AppIconArt.draw(in: rect, compact: size <= 32)
        }
      }
    }
    for (name, state) in [("recording", StatusIconArt.State.recording), ("paused", .paused), ("warning", .warning)] {
      for size in [18, 36, 54] {
        try png("\(base)/menubar/\(name)-\(size).png", size: size) { status(state, in: $0) }
      }
    }

    var favicons: [(Int, Data)] = []
    for size in [16, 32, 48] {
      let data = try png("web/public/icons/favicon-\(size).png", size: size) { rect in
        AppIconArt.drawBackground(in: rect)
        AppIconArt.drawMark(in: rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1), compact: true)
      }
      favicons.append((size, data))
    }
    try write(ico(favicons), "web/public/favicon.ico")
    try png("web/public/icons/apple-touch-icon.png", size: 180, draw: fullBleed)
    for size in [192, 512] {
      try png("web/public/icons/icon-\(size).png", size: size, draw: AppIconArt.draw)
      try png("web/public/icons/maskable-\(size).png", size: size, draw: fullBleed)
    }

    // 108dp 图层，标志外径约 49dp，不能把 66dp 安全圆当作目标填满尺寸。
    let densities: [(String, Double)] = [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]
    for (density, scale) in densities {
      let dir = "\(base)/android/res"
      try png("\(dir)/mipmap-\(density)/ic_launcher.png", size: Int(48 * scale), draw: AppIconArt.draw)
      try png("\(dir)/mipmap-\(density)/ic_launcher_round.png", size: Int(48 * scale)) { rect in
        NSBezierPath(ovalIn: rect).addClip(); fullBleed(rect)
      }
      for mono in [false, true] {
        let name = mono ? "ic_launcher_monochrome" : "ic_launcher_foreground"
        try png("\(dir)/drawable-\(density)/\(name).png", size: Int(108 * scale)) { rect in
          androidMark(rect, monochrome: mono)
        }
      }
      try png("\(dir)/drawable-\(density)/ic_stat_tacit.png", size: Int(24 * scale)) { status(.recording, in: $0, white: true, radiusRatio: 0.32) }
    }
    try text("""
    <?xml version="1.0" encoding="utf-8"?>
    <shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
      <solid android:color="#211F1D" />
    </shape>
    """, "\(base)/android/res/drawable/ic_launcher_background.xml")
    for version in [26, 33] {
      let mono = version == 33 ? "\n  <monochrome android:drawable=\"@drawable/ic_launcher_monochrome\" />" : ""
      for name in ["ic_launcher", "ic_launcher_round"] {
        try text("""
        <?xml version="1.0" encoding="utf-8"?>
        <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
          <background android:drawable="@drawable/ic_launcher_background" />
          <foreground android:drawable="@drawable/ic_launcher_foreground" />\(mono)
        </adaptive-icon>
        """, "\(base)/android/res/mipmap-anydpi-v\(version)/\(name).xml")
      }
    }
    try png("\(base)/android/play-store-512.png", size: 512, draw: fullBleed)

    // 预览由同一绘图源产生，不使用生图稿；菜单栏按实际像素显示。
    try png("\(base)/preview.png", size: 1200, height: 670) { rect in
      AppIconArt.rgb(0xFBFAF7).setFill(); rect.fill()
      AppIconArt.draw(in: CGRect(x: 30, y: 100, width: 500, height: 500))
      func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 18) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
          .font: NSFont.systemFont(ofSize: size), .foregroundColor: AppIconArt.rgb(0x1C1B1A)])
      }
      label("Tacit", 80, 595, size: 30)
      label("Continuing context", 80, 66)
      label("Web / favicon", 80, 25, size: 14)
      for (i, size) in [16, 32, 48].enumerated() {
        NSImage(contentsOf: root.appendingPathComponent("web/public/icons/favicon-\(size).png"))?
          .draw(in: CGRect(x: 220 + i * 80, y: 20, width: size, height: size))
      }
      label("macOS / Web", 590, 590)
      for (i, size) in [128, 64, 32, 16].enumerated() {
        AppIconArt.draw(in: CGRect(x: 580 + i * 145, y: 420, width: size, height: size), compact: size <= 32)
        label("\(size) px", CGFloat(590 + i * 145), 390, size: 14)
      }
      label("Menu bar / 18 px", 590, 330)
      AppIconArt.rgb(AppIconArt.background).setFill()
      CGRect(x: 825, y: 275, width: 220, height: 38).fill()
      for (i, state) in [StatusIconArt.State.recording, .paused, .warning].enumerated() {
        status(state, in: CGRect(x: 590 + i * 70, y: 285, width: 18, height: 18))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current!.cgContext.clip(to: CGRect(x: 840 + i * 70, y: 285, width: 18, height: 18))
        NSGraphicsContext.current!.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        status(state, in: CGRect(x: 840 + i * 70, y: 285, width: 18, height: 18), white: true)
        NSGraphicsContext.current!.cgContext.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
      }
      label("Android / adaptive masks", 590, 230)
      for i in 0..<3 {
        let tile = CGRect(x: 590 + i * 170, y: 70, width: 120, height: 120)
        NSGraphicsContext.saveGraphicsState()
        let mask = i == 0 ? NSBezierPath(ovalIn: tile) : NSBezierPath(roundedRect: tile, xRadius: i == 1 ? 28 : 8, yRadius: i == 1 ? 28 : 8)
        mask.addClip()
        AppIconArt.drawBackground(in: tile)
        // Launcher 的可见窗口是 72dp，原始前景图层 108dp。
        let layer = tile.insetBy(dx: -30, dy: -30)
        androidMark(layer, monochrome: i == 2)
        NSGraphicsContext.restoreGraphicsState()
      }
    }
    print("已导出并解码验证 \(pngCount) 个 PNG，以及 ICO 和 Android XML。")
  }
}
