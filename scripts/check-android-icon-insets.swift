import AppKit

// Pixel regression for the launcher ring touching the tile edge. Inspect rendered assets,
// not the drawing constants: the 108dp layer is cropped to a 72dp launcher viewport.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
  ? CommandLine.arguments[1] : "assets/icons/generated/android/res")
var failures: [String] = []
var checked = 0
for density in ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"] {
  for name in ["ic_launcher_foreground", "ic_launcher_monochrome"] {
    let path = "drawable-\(density)/\(name).png"
    guard let data = try? Data(contentsOf: root.appendingPathComponent(path)),
          let image = NSBitmapImageRep(data: data) else {
      failures.append("\(path): missing PNG"); continue
    }
    let size = image.pixelsWide
    var left = size, right = -1, top = size, bottom = -1
    for y in 0..<image.pixelsHigh {
      for x in 0..<size where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 {
        left = min(left, x); right = max(right, x)
        top = min(top, y); bottom = max(bottom, y)
      }
    }
    let viewport = Double(size) * 72 / 108
    let diameter = Double(max(right - left + 1, bottom - top + 1)) / viewport
    // The accepted full icon has a ring spanning ~69% of its dark tile. Allow raster rounding.
    let centered = abs(left - (size - 1 - right)) <= 1 && abs(top - (size - 1 - bottom)) <= 1
    if !(0.65...0.72).contains(diameter) || !centered || image.pixelsHigh != size {
      failures.append("\(path): ring covers \(Int((diameter * 100).rounded()))% of viewport; expected 65–72%, centered")
    }
    checked += 1
  }
}
if !failures.isEmpty {
  fputs(failures.joined(separator: "\n") + "\n", stderr)
  exit(1)
}
print("Android icon spacing: \(checked) rendered layers passed.")
