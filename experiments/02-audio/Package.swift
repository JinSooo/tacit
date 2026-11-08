// swift-tools-version:6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let lib = root + "/vendor/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib/lib"
let package = Package(
    name: "AudioExperiment", platforms: [.macOS(.v14)],
    products: [.executable(name: "bench", targets: ["Bench"]), .executable(name: "probe", targets: ["Probe"])],
    targets: [
        .systemLibrary(name: "CSherpa"),
        .target(name: "AudioCommon", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Bench", dependencies: ["CSherpa", "AudioCommon"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-L", lib, "-Xlinker", "-rpath", "-Xlinker", lib])]),
        .executableTarget(name: "Probe", dependencies: ["AudioCommon"], swiftSettings: [.swiftLanguageMode(.v5)])
    ])
