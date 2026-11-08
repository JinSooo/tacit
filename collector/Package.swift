// swift-tools-version:6.0
import PackageDescription

// CollectorCore：不依赖系统权限的纯逻辑（记录、切分、策略），可单测。
// Collector：菜单栏应用，负责辅助功能读取、OCR、剪贴板、插件调度和发送。
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let package = Package(
  name: "Collector",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "CollectorCore", swiftSettings: v5),
    .executableTarget(name: "Collector", dependencies: ["CollectorCore"], swiftSettings: v5),
    .testTarget(name: "CollectorCoreTests", dependencies: ["CollectorCore"], swiftSettings: v5),
  ]
)
