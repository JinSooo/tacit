import Foundation
import Testing
import CryptoKit
import AVFoundation
import CollectorCore
import AudioStore
@testable import ra_audio_worker

final class FakeModels: Inference {
  var transcriptions = 0
  var text: ([Float]) -> String = { _ in "合成测试文字" }
  func embedding(_ samples: [Float]) throws -> [Float] { [1] + Array(repeating: 0, count: 511) }
  func transcribe(_ samples: [Float]) throws -> Recognition { transcriptions += 1; return Recognition(text: text(samples), confidence: 0.9) }
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
  var uploads: [[String: Any]] = []
  var lineUploads: [[String: Any]] = []
  func request(_ path: String, body: Data?) async throws -> Data {
    paths.append(path)
    let json = try body.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
    var reply: [String: Any] = [:]
    if path.hasPrefix("/v1/audio/sync?") {
      let vector: [Float] = hit ? [1] + Array(repeating: 0, count: 511) : [0, 1] + Array(repeating: 0, count: 510)
      reply = ["retention_days": 7, "voiceprint": voice ? ["vector": vector, "threshold": 0.49] : NSNull(), "sample_requests": requests, "delete_conversations": [], "purge_before": NSNull()]
    } else if path == "/v1/audio/embeddings" {
      let speakers = json["speakers"] as! [[String: Any]]
      uploads.append(json)
      // 与 hub 一致：空说话人列表返回 400。
      if speakers.isEmpty { throw WorkerError.http }
      #expect(speakers.allSatisfy { ($0["centroid"] as? [Double])?.count == 512 })
      reply = ["speakers": speakers.map { ["local": $0["local"]!, "speaker_id": "speaker-test", "label": "说话人 A", "is_me": true] }]
    } else if path == "/v1/ingest" {
      records += json["records"] as! [[String: Any]]
      reply = ["accepted": reject || duplicate ? 0 : 1, "duplicates": duplicate ? 1 : 0, "rejected": reject ? [["index": 0]] : []]
    } else if path == "/v1/audio/lines" {
      lineUploads.append(json)
    } else if path == "/v1/audio/samples" {
      // 和 hub 一样：每个说话人（测试里只有一个）最多存 3 段。
      let stored = samples.reduce(0) { $0 + ($1["clips"] as! [Any]).count }
      guard stored + (json["clips"] as! [Any]).count <= 3 else { throw WorkerError.http }
      samples.append(json)
    }
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

// 回归：每段都短于 1.5 秒时算不出声纹，曾因上传空说话人被 hub 拒绝而一直 failed。
@Test func workerHandlesConversationTooShortForVoiceprint() async throws {
  let short: [Float] = Array(repeating: 0.1, count: 16000)
  for (voice, meetings, expected) in [(false, [String](), AudioStatus.waiting_me), (true, [], .skipped), (true, ["us.zoom.xos"], .done)] {
    let (root, store, _) = try fixture([short], meetings: meetings)
    defer { try? FileManager.default.removeItem(at: root) }
    let hub = FakeHub(); hub.voice = voice
    let worker = Worker(store: store, hub: hub, device: "mac-test") { FakeModels() }
    #expect(try await worker.run() == 0)
    #expect(try store.conversations().first?.status == expected)
    #expect(!hub.paths.contains("/v1/audio/embeddings"))
  }
}

// 回归：一段对话里同一说话人有多段连续人声时，旧逻辑一次请求发多段，占满 hub 的 3 段上限，其余请求永远 400。
@Test func workerSendsOneClipPerSampleRequest() async throws {
  let step = 2.0 * Double.pi * 440.0 / 16000.0
  let synthetic: [Float] = (0..<96000).map { Float(sin(Double($0) * step) * 0.2) }
  let (root, store, meta) = try fixture([synthetic, synthetic, synthetic], encode: { _ in Data([1, 2, 3]) })
  defer { try? FileManager.default.removeItem(at: root) }
  let hub = FakeHub(); hub.voice = false
  let worker = Worker(store: store, hub: hub, device: "mac-test", decode: { _ in synthetic }) { FakeModels() }
  #expect(try await worker.run() == 0)
  hub.requests = (1...3).map { ["id": "request-\($0)", "speaker_id": "speaker-test", "local": "S1", "conversation_ref": meta.id] }
  #expect(try await worker.run() == 0)
  #expect(hub.samples.count == 3)
  #expect(hub.samples.allSatisfy { ($0["clips"] as! [Any]).count == 1 })
}

// 回归：不开会时系统声音（音乐、视频）不进记录，它的说话人也不上传到待确认列表；开会时两路都保留。
@Test func workerDropsSystemAudioOutsideMeetings() async throws {
  let step = 2.0 * Double.pi * 440.0 / 16000.0
  let synthetic: [Float] = (0..<48000).map { Float(sin(Double($0) * step) * 0.2) }
  for meetings in [[], ["us.zoom.xos"]] {
    let (root, store, _) = try fixture([synthetic, synthetic], meetings: meetings, encode: { _ in Data([1, 2, 3]) })
    defer { try? FileManager.default.removeItem(at: root) }
    let hub = FakeHub(), models = FakeModels()
    let worker = Worker(store: store, hub: hub, device: "mac-test", decode: { _ in synthetic }) { models }
    #expect(try await worker.run() == 0)
    #expect(try store.conversations().first?.status == .done)
    let tracks = (hub.uploads.last?["speakers"] as? [[String: Any]])?.compactMap { $0["track"] as? String }
    let body = hub.records.first?["body"] as? String ?? ""
    let lines = body.split(separator: "\n").count
    if meetings.isEmpty {
      #expect(tracks == ["mic"]); #expect(lines == 1); #expect(models.transcriptions == 1)
    } else {
      #expect(Set(tracks ?? []) == ["mic", "sys"]); #expect(lines == 2)
    }
  }
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

// 本机分析用：RA_ECHO_PROBE=对话 id，读这台机器上的录音，比较旧的整句回声规则和新规则各去掉多少 mic 行。不上传、不写库。
@Test(.enabled(if: ProcessInfo.processInfo.environment["RA_ECHO_PROBE"] != nil, "需指定对话 id"))
func echoProbe() throws {
  let env = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: env["RA_DATA_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/record-anything"))
  let store = try AudioStore(dataDirectory: root)
  let models = try Models(directory: root.appendingPathComponent("models"))
  guard let meta = try store.conversations().first(where: { $0.id == env["RA_ECHO_PROBE"] }) else { Issue.record("找不到对话"); return }
  var lines: [TranscriptLine] = []
  for segment in meta.segments.sorted(by: { $0.t_start < $1.t_start }) {
    let text = try models.transcribe(WorkerLogic.trimPadding(AudioCodec.decode(store.readSegment(segment.file, meta: meta)))).text
    if !text.isEmpty { lines.append(TranscriptLine(segment: segment, local: "", text: text)) }
  }
  let mic = lines.filter { $0.segment.track == .mic }
  let old = mic.filter { m in !lines.contains { s in s.segment.track == .sys && m.segment.t_start < s.segment.t_end && s.segment.t_start < m.segment.t_end && WorkerLogic.similarity(m.text, s.text) >= 0.6 } }
  let new = WorkerLogic.removeEcho(lines).filter { $0.segment.track == .mic }
  print("echo_probe mic=\(mic.count) sys=\(lines.count - mic.count) old_kept=\(old.count) new_kept=\(new.count)")
  for l in new.prefix(15) { print("echo_probe kept \(l.segment.t_start.suffix(14)) \(l.text)") }
}

// 本机分析用：RA_BLEED_PROBE=对话 id，算每段 mic 和同时段 sys 的声纹相似度，看放歌、开会时能不能分开。
@Test(.enabled(if: ProcessInfo.processInfo.environment["RA_BLEED_PROBE"] != nil, "需指定对话 id"))
func bleedProbe() throws {
  let env = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/record-anything")
  let store = try AudioStore(dataDirectory: root)
  let models = try Models(directory: root.appendingPathComponent("models"))
  for id in env["RA_BLEED_PROBE"]!.split(separator: ",").map(String.init) {
    guard let meta = try store.conversations().first(where: { $0.id == id }) else { continue }
    let segs = meta.segments.sorted { $0.t_start < $1.t_start }
    func audio(_ s: AudioSegment) throws -> [Float] { WorkerLogic.trimPadding(try AudioCodec.decode(store.readSegment(s.file, meta: meta))) }
    var sysVec: [String: [Float]] = [:]
    for s in segs where s.track == .sys { let a = try audio(s); if a.count >= 8000 { sysVec[s.file] = try models.embedding(a) } }
    var scores: [(Double, String)] = []
    for m in segs where m.track == .mic {
      let a = try audio(m); guard a.count >= 8000 else { continue }
      let v = try models.embedding(a)
      let overl = segs.filter { $0.track == .sys && m.t_start < $0.t_end && $0.t_start < m.t_end }
      guard !overl.isEmpty else { scores.append((-2, "no-sys")); continue }
      let best = overl.compactMap { sysVec[$0.file] }.map { WorkerLogic.cosine(v, $0) }.max() ?? -1
      let text = try models.transcribe(a).text
      scores.append((best, text))
    }
    let withSys = scores.filter { $0.0 > -2 }
    print("bleed_probe \(id.suffix(6)) mic=\(scores.count) overlapping=\(withSys.count)")
    for t in [0.3, 0.4, 0.5, 0.6] { print("bleed_probe   >=\(t): \(withSys.filter { $0.0 >= t }.count)") }
    for (s, text) in withSys.sorted(by: { $0.0 > $1.0 }) { print(String(format: "bleed_probe   %.2f %@", s, String(text.prefix(30)))) }
  }
}

// 本机分析用：RA_CLUSTER_PROBE=对话 id，用新的归并重新算一遍说话人（只算不存、不上传），和"我"的声纹比。
@Test(.enabled(if: ProcessInfo.processInfo.environment["RA_CLUSTER_PROBE"] != nil, "需指定对话 id"))
func clusterProbe() throws {
  let env = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/record-anything")
  let store = try AudioStore(dataDirectory: root)
  let worker = Worker(store: store, hub: FakeHub(), device: "probe") { try Models(directory: root.appendingPathComponent("models")) }
  let me = env["RA_ME_VECTOR"].map { $0.split(separator: ",").compactMap { Float($0) } }
  for id in env["RA_CLUSTER_PROBE"]!.split(separator: ",").map(String.init) {
    guard var meta = try store.conversations().first(where: { $0.id == id }) else { continue }
    meta.segments.sort { $0.t_start == $1.t_start ? $0.file < $1.file : $0.t_start < $1.t_start }
    let c = try worker.computeClusters(meta)
    let labelled = meta.segments.indices.filter { i in c.windows.contains { $0.segment == i } }.count
    print("cluster_probe \(id.suffix(6)) speakers=\(c.speakers.count) segments=\(meta.segments.count) labelled=\(labelled)")
    for s in c.speakers.sorted(by: { $0.seconds > $1.seconds }) {
      print(String(format: "cluster_probe   %@ %@ %.0fs me=%.2f", s.local, s.track.rawValue, s.seconds, me.map { WorkerLogic.cosine($0, s.centroid) } ?? -9))
    }
  }
}

// 2026-11-11：旧版写进历史的对话按新规则重认一次（另存每句是谁），之后不再重复。
@Test func workerRelabelsOldConversationsOnce() async throws {
  let step = 2.0 * Double.pi * 440.0 / 16000.0
  let synthetic: [Float] = (0..<96000).map { Float(sin(Double($0) * step) * 0.2) }
  let (root, store, meta) = try fixture([synthetic], encode: { _ in Data([1, 2, 3]) })
  defer { try? FileManager.default.removeItem(at: root) }
  let hub = FakeHub()
  let worker = Worker(store: store, hub: hub, device: "mac-test", decode: { _ in synthetic }) { FakeModels() }
  #expect(try await worker.run() == 0)
  #expect(try store.conversations().first?.status == .done)
  #expect(!hub.paths.contains("/v1/audio/lines"))
  // 模拟上一版缓存和已完成标记：新版本仍须重认一次。
  let url = try store.directory(for: try store.conversations().first!).appendingPathComponent("speakers.json")
  var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  json["version"] = 3
  try JSONSerialization.data(withJSONObject: json).write(to: url)
  try Data().write(to: store.root.appendingPathComponent("relabel-v3"))
  #expect(try await worker.run() == 0)
  #expect(hub.paths.filter { $0 == "/v1/audio/lines" }.count == 1)
  #expect(try JSONDecoder().decode(SpeakerCache.self, from: Data(contentsOf: url)).version == 4)
  #expect(try await worker.run() == 0)
  #expect(hub.paths.filter { $0 == "/v1/audio/lines" }.count == 1)
  // 都重认完了，留下标记，采集端不再为此启动转写进程。
  #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(WorkerLogic.relabelMarker).path))
  _ = meta
}

// 两处生产路径都必须用文字确认：首次转写不跳过混合段，旧录音重认上传 visible。
@Test func workerMeetingBleedAndRelabelPreserveMixedSpeech() async throws {
  let question = "呃，这个chat指的是是图表是吗？图表对图表呃，那我们就先从phone开始，就先后开图表。"
  let system = "那我们就先从洞开始，就先抛开口掉。"
  let micAudio = [Float](repeating: 0.1, count: 48000), sysAudio = [Float](repeating: 0.2, count: 48000)
  for (meetings, micText, hidden) in [(["com.tencent.meeting"], question, false), (["com.tencent.meeting"], system, true), ([], question, true)] {
    let (root, store, original) = try fixture([micAudio, sysAudio], meetings: meetings, encode: { Data([$0[0] < 0.15 ? 1 : 2]) })
    defer { try? FileManager.default.removeItem(at: root) }
    var meta = original
    let start = AudioPolicy.date(meta.t_start)!
    meta.segments[1] = AudioSegment(file: meta.segments[1].file, track: .sys, start: start.addingTimeInterval(1), end: start.addingTimeInterval(4), dbfs: -20)
    try store.writeMetadata(meta)
    let hub = FakeHub(), models = FakeModels()
    models.text = { $0[0] < 0.15 ? micText : system }
    let worker = Worker(store: store, hub: hub, device: "mac-test", decode: { $0[0] == 1 ? micAudio : sysAudio }) { models }
    #expect(try await worker.run() == 0)
    let body = try #require(hub.records.first?["body"] as? String)
    let micClock = "[\(WorkerLogic.clock(meta.t_start, seconds: true))]"
    #expect(body.contains(micClock) == !hidden)
    if !hidden { #expect(body.contains(question)) }
    if !meetings.isEmpty { #expect(body.contains(system)) }
    let url = try worker.cacheURL(meta)
    var cache = try JSONDecoder().decode(SpeakerCache.self, from: Data(contentsOf: url))
    cache.version = 3
    try worker.save(cache, meta)
    #expect(try await worker.run() == 0)
    let uploaded = try #require(hub.lineUploads.last?["lines"] as? [[String: Any]])
    let mic = try #require(uploaded.first { $0["at"] as? String == WorkerLogic.clock(meta.t_start, seconds: true) })
    #expect(mic["hidden"] as? Bool == hidden)
    #expect(mic["speaker_id"] as? String == "speaker-test")
    #expect(try await worker.run() == 0)
    #expect(hub.lineUploads.count == 1)
  }
}
