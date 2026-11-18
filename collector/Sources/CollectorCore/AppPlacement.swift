import Foundation

/// 应用所在位置决定启动时做什么：装在“应用程序”里才准备后台服务；
/// 从安装盘或被系统随机挪动（App Translocation）的位置打开时，先请用户拖进“应用程序”。
public enum AppPlacement: Equatable {
  case installed, mustMove, elsewhere

  public static func of(bundlePath: String, home: String) -> AppPlacement {
    if bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/") { return .mustMove }
    let parent = (bundlePath as NSString).deletingLastPathComponent
    return parent == "/Applications" || parent == (home as NSString).appendingPathComponent("Applications") ? .installed : .elsewhere
  }
}
