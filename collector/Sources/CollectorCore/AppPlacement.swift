import Foundation

/// 应用所在位置决定启动时做什么：装在“应用程序”里才准备后台服务；
/// 安装盘、系统转移的临时位置和装错位置的打包版，先请用户拖进“应用程序”。
public enum AppPlacement: Equatable {
  case installed, mustMove, elsewhere

  public static func of(bundlePath: String, home: String, hasBundledRuntime: Bool = false) -> AppPlacement {
    if bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/") { return .mustMove }
    let parent = (bundlePath as NSString).deletingLastPathComponent
    if parent == "/Applications" || parent == (home as NSString).appendingPathComponent("Applications") { return .installed }
    guard hasBundledRuntime else { return .elsewhere }
    // collector/build.sh 产出的源码构建也带运行时，开发时可以直接运行。
    let build = URL(fileURLWithPath: parent)
    let source = build.deletingLastPathComponent()
    if ["build", ".build"].contains(build.lastPathComponent), source.lastPathComponent == "collector",
       FileManager.default.fileExists(atPath: source.appendingPathComponent("Package.swift").path) { return .elsewhere }
    return .mustMove
  }
}
