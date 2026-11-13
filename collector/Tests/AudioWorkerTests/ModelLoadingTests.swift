import Foundation
import Testing
import Darwin
@testable import ra_audio_worker

@Test func modelsDoNotLoadUnusedResourcesAtConstruction() throws {
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  // 只创建后端、尚未请求任何推理，不应读取转写或声纹模型。
  _ = try Models(directory: missing)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RA_MODEL_PROBE"] != nil))
func speakerOnlyRuntimeProbe() throws {
  let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RA_MODEL_PROBE"]!)
  let started = Date()
  let models = try Models(directory: root)
  let samples = (0..<48000).map { Float(sin(Double($0) * 2 * Double.pi * 440 / 16000) * 0.2) }
  #expect(try models.embedding(samples).count == 512)
  var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
  print("speaker-only probe seconds=\(Date().timeIntervalSince(started)) peak_rss_bytes=\(usage.ru_maxrss)")
}
