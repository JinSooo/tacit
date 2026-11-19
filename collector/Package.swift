// swift-tools-version:6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let lib = root + "/vendor/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib/lib"

// CollectorCore：不依赖系统权限的纯逻辑（记录、切分、策略），可单测。
// Collector：菜单栏应用，负责辅助功能读取、OCR、剪贴板、插件调度和发送。
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let package = Package(
  name: "Collector",
  platforms: [.macOS(.v14)],
  products: [.library(name: "AudioStore", targets: ["AudioStore"])],
  targets: [
    .systemLibrary(name: "CSherpa"),
    .target(name: "AudioStore", dependencies: ["CollectorCore"], swiftSettings: v5),
    .target(name: "CollectorCore", swiftSettings: v5),
    .executableTarget(name: "ra-audio-worker", dependencies: ["AudioStore", "CollectorCore", "CSherpa"], path: "Sources/AudioWorker", swiftSettings: v5,
      linkerSettings: [.unsafeFlags(["-L", lib, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    // 测试直接运行构建产物，不在 app 包内；只有测试使用本地 vendor 的 rpath。
    .testTarget(name: "AudioWorkerTests", dependencies: ["ra-audio-worker", "AudioStore", "CollectorCore"], swiftSettings: v5,
      linkerSettings: [.unsafeFlags(["-L", lib, "-Xlinker", "-rpath", "-Xlinker", lib])]),
    .executableTarget(name: "Collector", dependencies: ["CollectorCore", "AudioStore", "CSherpa"], swiftSettings: v5,
      linkerSettings: [.unsafeFlags(["-L", lib, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "CollectorTests", dependencies: ["Collector"], swiftSettings: v5,
      linkerSettings: [.unsafeFlags(["-L", lib, "-Xlinker", "-rpath", "-Xlinker", lib])]),
    .testTarget(name: "AudioStoreTests", dependencies: ["AudioStore"], swiftSettings: v5),
    .testTarget(name: "CollectorCoreTests", dependencies: ["CollectorCore"], swiftSettings: v5),
  ]
)
