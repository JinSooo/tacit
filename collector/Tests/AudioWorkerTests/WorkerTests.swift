import Foundation
import Testing
import CryptoKit
import AVFoundation
import CollectorCore
import AudioStore
@testable import ra_audio_worker

final class FakeModels: Inference {
  var transcriptions = 0
  func embedding(_ samples: [Float]) throws -> [Float] { [1] + Array(repeating: 0, count: 511) }
  func transcribe(_ samples: [Float]) throws -> Recognition { transcriptions += 1; return Recognition(text: "合成测试文字", confidence: 0.9) }
}
final class FakeHub: HubTransport {
  var voice = true
  var hit = true
  var reject = false
  var duplicate = false
  var paths: [String] = []
  var records: [[String: Any]] = []
  var requests: [[String: Any]] = []
  var samples: [[String: Any]] = []
  func request(_ path: String, body: Data?) async throws -> Data {
    paths.append(path)
    let json = try body.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
    var reply: [String: Any] = [:]
    if path.hasPrefix("/v1/audio/sync?") {
      let vector: [Float] = hit ? [1] + Array(repeating: 0, count: 511) : [0, 1] + Array(repeating: 0, count: 510)
      reply = ["retention_days": 7, "voiceprint": voice ? ["vector": vector, "threshold": 0.49] : NSNull(), "sample_requests": requests, "delete_conversations": [], "purge_before": NSNull()]
    } else if path == "/v1/audio/embeddings" {
      let speakers = json["speakers"] as! [[String: Any]]
      #expect(speakers.allSatisfy { ($0["centroid"] as? [Double])?.count == 512 })
      reply = ["speakers": speakers.map { ["local": $0["local"]!, "speaker_id": "speaker-test", "label": "说话人 A", "is_me": true] }]
    } else if path == "/v1/ingest" {
      records += json["records"] as! [[String: Any]]
      reply = ["accepted": reject || duplicate ? 0 : 1, "duplicates": duplicate ? 1 : 0, "rejected": reject ? [["index": 0]] : []]
    } else if path == "/v1/audio/samples" { samples.append(json) }
    return try JSONSerialization.data(withJSONObject: reply)
  }
}
func fixture(_ samples: [[Float]], meetings: [String] = [], encode: ([Float]) throws -> Data = AudioCodec.encode) throws -> (URL, AudioStore, AudioMetadata) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-test-" + UUID().uuidString)
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let start = Date().addingTimeInterval(-120)
  var meta = AudioMetadata(start: start); meta.meeting_apps = meetings
  var offset = 0.0
  for (i, audio) in samples.enumerated() {
    let track: AudioTrack = i % 2 == 0 ? .mic : .sys
    let file = String(format: "%@-%04d.enc", track.rawValue, i + 1)
    let duration = Double(audio.count) / 16000
    meta.segments.append(AudioSegment(file: file, track: track, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + duration), dbfs: -20))
    try store.writeSegment(encode(audio), file: file, meta: meta)
    offset += duration + 1
  }
  meta.t_end = LocalTime.iso(start.addingTimeInterval(offset))
  try meta.transition(to: .closed, at: Date()); try store.writeMetadata(meta)
  return (root, store, meta)
}

@Test func workerWaitingRetryDuplicateSamplesAndSkipped() async throws {
  let step = 2.0 * Double.pi * 440.0 / 16000.0
  let synthetic: [Float] = (0..<96000).map { Float(sin(Double($0) * step) * 0.2) }
  let (root, store, meta) = try fixture([synthetic], encode: { _ in Data([1, 2, 3]) })
  defer { try? FileManager.default.removeItem(at: root) }
  let hub = FakeHub(), models = FakeModels()
  let worker = Worker(store: store, hub: hub, device: "mac-test", decode: { _ in synthetic }) { models }
  hub.voice = false
  #expect(try await worker.run() == 0)
  #expect(try store.conversations().first?.status == .waiting_me)
  #expect(models.transcriptions == 0)
  let original = try Data(contentsOf: store.directory(for: meta).appendingPathComponent("speakers.json"))
  hub.voice = true; hub.reject = true
  #expect(try await worker.run() == 1)
  #expect(try store.conversations().first?.status == .failed)
  #expect(try store.conversations().first?.attempts == 1)
  hub.reject = false; hub.duplicate = true
  hub.requests = [["id": "request-test", "speaker_id": "speaker-test", "local": "S1", "conversation_ref": meta.id]]
  #expect(try await worker.run() == 0)
  #expect(try store.conversations().first?.status == .done)
  #expect(!hub.samples.isEmpty)
  let clips = hub.samples[0]["clips"] as! [[String: String]]
  #expect(clips.count <= 3)
  #expect(clips.allSatisfy { Data(base64Encoded: $0["data"]!)!.count <= 320044 })
  let cached = try Data(contentsOf: store.directory(for: meta).appendingPathComponent("speakers.json"))
  #expect(try JSONDecoder().decode(SpeakerCache.self, from: original).windows == JSONDecoder().decode(SpeakerCache.self, from: cached).windows)
  let (otherRoot, otherStore, _) = try fixture([synthetic], encode: { _ in Data([1, 2, 3]) })
  defer { try? FileManager.default.removeItem(at: otherRoot) }
  let otherHub = FakeHub(); otherHub.hit = false
  let other = Worker(store: otherStore, hub: otherHub, device: "mac-test", decode: { _ in synthetic }) { FakeModels() }
  #expect(try await other.run() == 0)
  #expect(try otherStore.conversations().first?.status == .skipped)
  #expect(otherHub.records.isEmpty)
  #expect(otherHub.paths.contains { $0.hasSuffix("/skipped") })
}

@Test func workerContinuesAfterCorruptConversationAndCapsRetries() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  var ids: [String] = []
  for n in 0..<2 {
    let start = Date().addingTimeInterval(Double(n - 120))
    var meta = AudioMetadata(start: start)
    meta.t_end = LocalTime.iso(start.addingTimeInterval(2))
    meta.segments = [AudioSegment(file: "mic-0001.enc", track: .mic, start: start, end: start.addingTimeInterval(2), dbfs: -20)]
    try meta.transition(to: .closed, at: Date()); try store.writeMetadata(meta); ids.append(meta.id)
  }
  let hub = FakeHub(), models = FakeModels()
  let worker = Worker(store: store, hub: hub, device: "mac-test") { models }
  for _ in 0..<3 { #expect(try await worker.run() == 2) }
  #expect(try await worker.run() == 0)
  #expect(try store.conversations().allSatisfy { $0.status == .failed && $0.attempts == 3 && $0.error == "音频处理失败" })
  #expect(models.transcriptions == 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RA_WORKER_SMOKE_MODELS"] != nil, "用 collector/scripts/worker-smoke.sh 运行真实模型集成测试"))
func vendorWorkerSmoke() async throws {
  let env = ProcessInfo.processInfo.environment
  let source = URL(fileURLWithPath: env["RA_WORKER_SMOKE_VENDOR"]!)
  func read(_ name: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: source.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/test_wavs/\(name).wav"))
    #expect(file.processingFormat.sampleRate == 16000)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }
  let (root, store, meta) = try fixture([read("zh"), read("en")], meetings: ["us.zoom.xos"])
  defer { try? FileManager.default.removeItem(at: root) }
  let models = URL(fileURLWithPath: env["RA_WORKER_SMOKE_MODELS"]!)
  let transport: any HubTransport
  if let url = env["RA_WORKER_SMOKE_HUB"] { transport = Hub(base: URL(string: url)!, token: "synthetic-token") }
  else { transport = FakeHub() }
  let worker = Worker(store: store, hub: transport, device: "mac-test") { try Models(directory: models) }
  #expect(try await worker.run() == 0)
  #expect(try store.conversations().first?.status == .done)
  #expect(try store.conversations().first?.id == meta.id)
}

// 沙箱没有 AAC 编码服务或监听权限时，单独测真实模型；不冒充完整加密/AAC/HTTP 链路。
@Test(.enabled(if: ProcessInfo.processInfo.environment["RA_WORKER_BENCH_VENDOR"] != nil, "需指定只读 vendor 目录"))
func vendorInferenceBenchmark() throws {
  let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RA_WORKER_BENCH_VENDOR"]!)
  let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: staging) }
  try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("sense-voice"), withDestinationURL: source.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"))
  let speaker = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
  try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent(speaker), withDestinationURL: source.appendingPathComponent(speaker))
  let load = Date()
  let models = try Models(directory: staging)
  print("模型加载 seconds=\(Date().timeIntervalSince(load))")
  let begin = Date()
  var speakers: [LocalSpeaker] = []
  for (i, name) in ["zh", "en"].enumerated() {
    let file = try AVAudioFile(forReading: source.appendingPathComponent("sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/test_wavs/\(name).wav"))
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: pcm)
    let samples = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
    let start = Date()
    for window in WorkerLogic.windows(count: samples.count, segment: i) {
      let vector = try models.embedding(Array(samples[window.offset..<(window.offset + window.count)]))
      #expect(vector.count == 512)
      _ = WorkerLogic.assign(vector: vector, track: i == 0 ? .mic : .sys, seconds: Double(window.count) / 16000, speakers: &speakers)
    }
    let recognized = try models.transcribe(samples)
    #expect(!recognized.text.isEmpty)
    print("vendor=\(name) confidence_available=\(recognized.confidence == nil ? 0 : 1)")
    print("vendor=\(name) audio_seconds=\(Double(samples.count) / 16000) processing_seconds=\(Date().timeIntervalSince(start))")
  }
  var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
  print("vendor_conversation segments=2 seconds=\(Date().timeIntervalSince(begin)) peak_rss_bytes=\(usage.ru_maxrss)")
}
