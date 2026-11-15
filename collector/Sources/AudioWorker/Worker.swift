import Foundation
import CollectorCore
import AudioStore
import Darwin

struct Voiceprint: Decodable { let vector: [Float]; let threshold: Double }
struct SampleRequest: Decodable { let id: String; let speaker_id: String; let conversation_ref: String; let local: String }
struct Sync: Decodable {
  let retention_days: Int
  let voiceprint: Voiceprint?
  let sample_requests: [SampleRequest]
  let purge_before: String?
  let delete_conversations: [String]
}
struct HubSpeaker: Codable { let local: String; let speaker_id: String; let label: String; let is_me: Bool }
struct EmbeddingsResponse: Decodable { let speakers: [HubSpeaker] }
protocol HubTransport { func request(_ path: String, body: Data?) async throws -> Data }
final class Hub: HubTransport {
  let base: URL; let token: String
  init(base: URL, token: String) { self.base = base; self.token = token }
  func request(_ path: String, body: Data? = nil) async throws -> Data {
    guard let url = URL(string: path, relativeTo: base) else { throw WorkerError.arguments }
    var req = URLRequest(url: url); req.timeoutInterval = 120
    req.httpMethod = body == nil ? "GET" : "POST"; req.httpBody = body
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // 不跟随重定向，避免把 token 或音频样本送往其他地址。
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: req)
    guard let r = response as? HTTPURLResponse, (200..<300).contains(r.statusCode) else { throw WorkerError.http }
    return data
  }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
// 只含窗口位置、声纹和 hub id；不保存文字或明文音频。首次上传前原子落盘，重跑及样本请求复用完全相同的 S 编号。
struct SpeakerCache: Codable {
  let segments: [AudioSegment]
  let windows: [VoiceWindow]
  let speakers: [LocalSpeaker]
  var hub: [HubSpeaker]
  /// 2：归并说话人并识别短段；3：扩展扬声器声音；4：会议隐藏需同时有声纹和文字覆盖。旧录音按新规则重认。
  var version: Int? = nil
  static let current = 4
}
final class Worker {
  let store: AudioStore; let hub: any HubTransport; let device: String
  let loadModels: () throws -> any Inference
  let decode: (Data) throws -> [Float]
  private var models: (any Inference)?
  init(store: AudioStore, hub: any HubTransport, device: String, decode: @escaping (Data) throws -> [Float] = AudioCodec.decode, loadModels: @escaping () throws -> any Inference) {
    self.store = store; self.hub = hub; self.device = device; self.decode = decode; self.loadModels = loadModels
  }
  func inference() throws -> any Inference {
    if let models { return models }; let m = try loadModels(); models = m; return m
  }
  func post(_ path: String, _ body: [String: Any]) async throws -> Data {
    try await hub.request(path, body: JSONSerialization.data(withJSONObject: body))
  }
  func audio(_ segment: AudioSegment, _ meta: AudioMetadata) throws -> [Float] {
    let decoded = try decode(store.readSegment(segment.file, meta: meta))
    return WorkerLogic.trimPadding(decoded)
  }
  func cacheURL(_ meta: AudioMetadata) throws -> URL {
    let url = try store.directory(for: meta).appendingPathComponent("speakers.json")
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw WorkerError.cache }
    return url
  }
  func save(_ cache: SpeakerCache, _ meta: AudioMetadata) throws {
    let url = try cacheURL(meta)
    try store.writePrivateData(JSONEncoder().encode(cache), to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func clustered(_ meta: AudioMetadata) throws -> SpeakerCache {
    let url = try cacheURL(meta)
    if FileManager.default.fileExists(atPath: url.path) {
      let cache = try JSONDecoder().decode(SpeakerCache.self, from: store.readPrivateData(at: url))
      guard cache.segments == meta.segments else { throw WorkerError.cache }; return cache
    }
    let cache = try computeClusters(meta)
    try save(cache, meta); return cache
  }
  /// 只算不存：给 clustered 和本机分析用。
  func computeClusters(_ meta: AudioMetadata) throws -> SpeakerCache {
    var windows: [VoiceWindow] = [], speakers: [LocalSpeaker] = [], short: [(segment: Int, count: Int, vector: [Float])] = []
    for (index, segment) in meta.segments.enumerated() {
      let samples = try audio(segment, meta)
      let ws = WorkerLogic.windows(count: samples.count, segment: index)
      for var window in ws {
        let vector = try inference().embedding(Array(samples[window.offset..<(window.offset + window.count)]))
        window.local = WorkerLogic.assign(vector: vector, track: segment.track, seconds: Double(window.count) / 16000, speakers: &speakers)
        windows.append(window)
      }
      // 不到 1.5 秒的段算不出稳定声纹，以前一律记成"未知说话人"；先留着声纹，归并后再认是谁（不参与说话人中心）。
      if ws.isEmpty, samples.count >= WorkerLogic.shortSegmentSamples { short.append((index, samples.count, try inference().embedding(samples))) }
    }
    WorkerLogic.apply(WorkerLogic.consolidate(speakers), windows: &windows, speakers: &speakers)
    for s in short {
      if let local = WorkerLogic.nearest(s.vector, track: meta.segments[s.segment].track, speakers: speakers) {
        windows.append(VoiceWindow(segment: s.segment, offset: 0, count: s.count, local: local))
      }
    }
    return SpeakerCache(segments: meta.segments, windows: windows, speakers: speakers, hub: [], version: SpeakerCache.current)
  }
  /// 麦克风那路里其实是扬声器声音的段（和同时播放的系统声音是同一个声音）。
  func bleedSegments(_ meta: AudioMetadata, windows: [VoiceWindow]) throws -> Set<Int> {
    var sysVoice: [Int: [Float]] = [:], out = Set<Int>()
    func voice(_ i: Int) throws -> [Float]? {
      if let v = sysVoice[i] { return v }
      let a = try audio(meta.segments[i], meta)
      guard a.count >= WorkerLogic.shortSegmentSamples else { return nil }
      let v = try inference().embedding(a); sysVoice[i] = v; return v
    }
    for (i, segment) in meta.segments.enumerated() where segment.track == .mic {
      let overlapping = meta.segments.indices.filter { j in
        meta.segments[j].track == .sys && AudioPolicy.date(segment.t_start)! < AudioPolicy.date(meta.segments[j].t_end)! && AudioPolicy.date(meta.segments[j].t_start)! < AudioPolicy.date(segment.t_end)!
      }
      guard !overlapping.isEmpty else { continue }
      let a = try audio(segment, meta)
      guard a.count >= WorkerLogic.shortSegmentSamples else { continue }
      if WorkerLogic.isBleed(mic: try inference().embedding(a), sys: try overlapping.compactMap(voice)) { out.insert(i) }
    }
    // 会议里每段都要独立命中声纹，不能因同一说话人的其他段像回声就一起隐藏。
    return meta.meeting_apps.isEmpty ? WorkerLogic.expandBleed(out, windows: windows, segments: meta.segments) : out
  }
  func transcribe(_ meta: AudioMetadata, windows: [VoiceWindow], skipping: Set<Int> = []) throws -> [TranscriptLine] {
    var lines: [TranscriptLine] = []
    for (i, segment) in meta.segments.enumerated() {
      // 非会议的系统转写只辅助去回声，不写进记录。
      if meta.meeting_apps.isEmpty && segment.track == .sys && !WorkerLogic.overlapsMic(segment, meta.segments) { continue }
      if skipping.contains(i) { continue }
      let recognition = try inference().transcribe(audio(segment, meta))
      if !recognition.text.isEmpty {
        lines.append(TranscriptLine(segment: segment, local: WorkerLogic.majority(windows.filter { $0.segment == i }), text: recognition.text, confidence: recognition.confidence))
      }
    }
    return lines
  }
  /// 已经写进历史的对话按新规则重新认人：记录不改，每句是谁、哪句是扬声器声音另存在 hub（AGENTS.md：归属关系另存一张表）。
  func relabel(_ meta: AudioMetadata) async throws {
    var cache = try computeClusters(meta)
    let meeting = !meta.meeting_apps.isEmpty
    let uploaded = cache.speakers.filter { meeting || $0.track == .mic }
    if !uploaded.isEmpty {
      let response = try await post("/v1/audio/embeddings", ["device": device, "conversation_ref": meta.id, "t_start": meta.t_start,
        "t_end": meta.t_end!, "speakers": uploaded.map { ["local": $0.local, "track": $0.track.rawValue, "seconds": $0.seconds, "centroid": $0.centroid] as [String: Any] }])
      cache.hub = try JSONDecoder().decode(EmbeddingsResponse.self, from: response).speakers
    }
    let candidates = try bleedSegments(meta, windows: cache.windows)
    let transcripts = meeting ? try transcribe(meta, windows: cache.windows) : []
    let bleed = WorkerLogic.confirmedBleed(candidates, segments: meta.segments, lines: transcripts, meeting: meeting)
    let ids = Dictionary(uniqueKeysWithValues: cache.hub.map { ($0.local, $0.speaker_id) })
    let lines: [[String: Any]] = meta.segments.enumerated().compactMap { i, segment in
      if !meeting && segment.track == .sys { return nil }
      let local = WorkerLogic.majority(cache.windows.filter { $0.segment == i })
      return ["at": WorkerLogic.clock(segment.t_start, seconds: true), "speaker_id": ids[local] as Any? ?? NSNull(), "hidden": bleed.contains(i)]
    }
    _ = try await post("/v1/audio/lines", ["device": device, "conversation_ref": meta.id, "lines": lines])
    try save(cache, meta)
  }
  func run() async throws -> Int {
    let sync = try JSONDecoder().decode(Sync.self, from: await hub.request("/v1/audio/sync?device=\(device)", body: nil))
    guard (0...365).contains(sync.retention_days), sync.voiceprint.map({ $0.vector.count == 512 && $0.vector.allSatisfy(\.isFinite) && WorkerLogic.unit($0.vector).count == 512 && $0.threshold.isFinite && (0...1).contains($0.threshold) }) ?? true else { throw WorkerError.response }
    let all = try store.conversations().sorted { AudioPolicy.date($0.t_start)! < AudioPolicy.date($1.t_start)! }
    var failures = 0
    for var meta in all where meta.status == .closed || (meta.status == .failed && (meta.attempts ?? 0) < 3) || (meta.status == .waiting_me && sync.voiceprint != nil) {
      // 删除同步由采集端执行；尚未 ack 的删除或清理不得重新上传。
      if sync.delete_conversations.contains(meta.id) || AudioPolicy.shouldDelete(meta, now: Date(), retentionDays: sync.retention_days, purgeBefore: AudioPolicy.date(sync.purge_before)) { continue }
      let start = Date()
      do {
        meta.segments.sort {
          let a = AudioPolicy.date($0.t_start)!, b = AudioPolicy.date($1.t_start)!
          return a == b ? $0.file < $1.file : a < b
        }
        var cache = try clustered(meta)
        // 不开会时系统声音不转写，它的说话人也不上传，不进待确认列表。
        let meeting = !meta.meeting_apps.isEmpty
        let uploaded = cache.speakers.filter { meeting || $0.track == .mic }
        // 每段都不足 1.5 秒时算不出声纹：不上传，按"没有可识别说话人"走后面的判定。
        if uploaded.isEmpty { cache.hub = [] } else {
          let response = try await post("/v1/audio/embeddings", ["device": device, "conversation_ref": meta.id, "t_start": meta.t_start,
            "t_end": meta.t_end!, "speakers": uploaded.map { ["local": $0.local, "track": $0.track.rawValue, "seconds": $0.seconds, "centroid": $0.centroid] as [String: Any] }])
          cache.hub = try JSONDecoder().decode(EmbeddingsResponse.self, from: response).speakers
        }
        guard Set(cache.hub.map(\.local)) == Set(uploaded.map(\.local)), Set(cache.hub.map(\.local)).count == cache.hub.count else { throw WorkerError.response }
        try save(cache, meta)
        let next = WorkerLogic.decision(speakers: cache.speakers, voiceprint: sync.voiceprint?.vector, threshold: sync.voiceprint?.threshold ?? 1, meetings: meta.meeting_apps)
        if next == .skipped { _ = try await post("/v1/audio/conversations/\(meta.id)/skipped", [:]) }
        if next == .done {
          let candidates = try bleedSegments(meta, windows: cache.windows)
          let lines = try transcribe(meta, windows: cache.windows, skipping: meeting ? [] : candidates)
          let bleed = WorkerLogic.confirmedBleed(candidates, segments: meta.segments, lines: lines, meeting: meeting)
          let hiddenFiles = Set(bleed.map { meta.segments[$0].file })
          let kept = meeting ? lines.filter { !hiddenFiles.contains($0.segment.file) } : WorkerLogic.removeEcho(lines)
          let labels = Dictionary(uniqueKeysWithValues: cache.hub.map { ($0.local, $0.is_me ? "我" : $0.label) })
          let ids = Dictionary(uniqueKeysWithValues: cache.hub.map { ($0.local, $0.speaker_id) })
          let record = WorkerLogic.record(meta: meta, device: device, lines: kept.filter { meeting || $0.segment.track == .mic }, labels: labels, ids: ids, retention: sync.retention_days)
          guard (record["body"] as! String).unicodeScalars.count <= 200000 else { throw WorkerError.recordTooLarge }
          let response = try await post("/v1/ingest", ["device": device, "records": [record]])
          guard let receipt = DeliveryReceipt.decode(response, batchCount: 1), receipt.rejected.isEmpty else { throw WorkerError.response }
        }
        var completed = meta
        try completed.transition(to: next, at: Date()); try store.writeMetadata(completed); meta = completed
      } catch {
        failures += 1
        // 不序列化底层异常；HTTP 错误可能携带请求内容或服务端转写文字。
        do {
          try meta.transition(to: .failed, at: Date(), error: "音频处理失败")
          try store.writeMetadata(meta)
        } catch { fputs("\(meta.id) metadata_failed\n", stderr) }
      }
      var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
      fputs("\(meta.id) \(meta.status.rawValue) segments=\(meta.segments.count) seconds=\(String(format: "%.3f", Date().timeIntervalSince(start))) peak_rss_bytes=\(usage.ru_maxrss)\n", stderr)
    }
    // 旧版写进历史的对话按新规则重认，每次最多花 5 分钟，剩下的下次接着做。
    let relabelUntil = Date().addingTimeInterval(300)
    var relabelLeft = false
    for meta in all.reversed() where meta.status == .done {
      guard Date() < relabelUntil else { relabelLeft = true; break }
      if sync.delete_conversations.contains(meta.id) || AudioPolicy.shouldDelete(meta, now: Date(), retentionDays: sync.retention_days, purgeBefore: AudioPolicy.date(sync.purge_before)) { continue }
      let current = (try? cacheURL(meta)).flatMap { try? store.readPrivateData(at: $0) }.flatMap { try? JSONDecoder().decode(SpeakerCache.self, from: $0) }
      if current?.version == SpeakerCache.current { continue }
      var sorted = meta
      sorted.segments.sort { AudioPolicy.date($0.t_start)! == AudioPolicy.date($1.t_start)! ? $0.file < $1.file : AudioPolicy.date($0.t_start)! < AudioPolicy.date($1.t_start)! }
      do { try await relabel(sorted) } catch { relabelLeft = true; failures += 1; fputs("\(meta.id) relabel_failed\n", stderr) }
    }
    let marker = store.root.appendingPathComponent(WorkerLogic.relabelMarker)
    if !relabelLeft, !FileManager.default.fileExists(atPath: marker.path) { FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
    for request in sync.sample_requests {
      guard var meta = all.first(where: { $0.id == request.conversation_ref }), meta.status != .open,
        !sync.delete_conversations.contains(meta.id), !AudioPolicy.shouldDelete(meta, now: Date(), retentionDays: sync.retention_days, purgeBefore: AudioPolicy.date(sync.purge_before)) else { continue }
      do {
        meta.segments.sort { AudioPolicy.date($0.t_start)! == AudioPolicy.date($1.t_start)! ? $0.file < $1.file : AudioPolicy.date($0.t_start)! < AudioPolicy.date($1.t_start)! }
        let cache = try clustered(meta)
        guard cache.hub.contains(where: { $0.local == request.local && $0.speaker_id == request.speaker_id }) else { continue }
        // hub 每个说话人最多存 3 段、每段对话发一次请求：每次只发该说话人在段对话里最响的一段，
        // 3 段样本分别来自 3 段对话。只截连续窗口，避免混入其他人的试听。
        // 用户报告：按"最长"选会把远处、隔墙的细微声音当成样本，听不出是谁。
        let candidates = meta.segments.indices.filter { i in cache.windows.contains { $0.segment == i && $0.local == request.local && $0.count >= 24000 } }
          .sorted { meta.segments[$0].dbfs > meta.segments[$1].dbfs }
        var best: (segment: Int, range: Range<Int>, dbfs: Double)?
        // 先按整段响度排，最多解码前 3 段找最响的连续窗口。
        for i in candidates.prefix(3) {
          let samples = try audio(meta.segments[i], meta)
          let runs = WorkerLogic.runs(cache.windows.filter { $0.segment == i && $0.local == request.local && $0.count >= 24000 })
          guard let loudest = WorkerLogic.loudest(runs, in: samples, limit: 96000), loudest.dbfs.isFinite else { continue }
          if best == nil || loudest.dbfs > best!.dbfs { best = (i, loudest.range, loudest.dbfs) }
        }
        if let best {
          let samples = try audio(meta.segments[best.segment], meta)
          let end = min(best.range.upperBound, best.range.lowerBound + 160000)
          guard end <= samples.count else { throw WorkerError.cache }
          let clip = ["mime": "audio/wav", "data": WorkerLogic.wav(WorkerLogic.normalize(Array(samples[best.range.lowerBound..<end]))).base64EncodedString()]
          _ = try await post("/v1/audio/samples", ["request_id": request.id, "clips": [clip]])
        }
      } catch { failures += 1; fputs("\(meta.id) sample_failed\n", stderr) }
    }
    return failures
  }
}
