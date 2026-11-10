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
struct IngestResponse: Decodable { let accepted: Int; let duplicates: Int; let rejected: [Rejection] }
struct Rejection: Decodable { let index: Int }
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
    try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func clustered(_ meta: AudioMetadata) throws -> SpeakerCache {
    let url = try cacheURL(meta)
    if FileManager.default.fileExists(atPath: url.path) {
      let cache = try JSONDecoder().decode(SpeakerCache.self, from: Data(contentsOf: url))
      guard cache.segments == meta.segments else { throw WorkerError.cache }; return cache
    }
    var windows: [VoiceWindow] = [], speakers: [LocalSpeaker] = []
    for (index, segment) in meta.segments.enumerated() {
      let samples = try audio(segment, meta)
      for var window in WorkerLogic.windows(count: samples.count, segment: index) {
        let vector = try inference().embedding(Array(samples[window.offset..<(window.offset + window.count)]))
        window.local = WorkerLogic.assign(vector: vector, track: segment.track, seconds: Double(window.count) / 16000, speakers: &speakers)
        windows.append(window)
      }
    }
    let cache = SpeakerCache(segments: meta.segments, windows: windows, speakers: speakers, hub: [])
    try save(cache, meta); return cache
  }
  func run() async throws -> Int {
    let sync = try JSONDecoder().decode(Sync.self, from: await hub.request("/v1/audio/sync?device=\(device)", body: nil))
    guard (1...365).contains(sync.retention_days), sync.voiceprint.map({ $0.vector.count == 512 && $0.vector.allSatisfy(\.isFinite) && WorkerLogic.unit($0.vector).count == 512 && $0.threshold.isFinite && (0...1).contains($0.threshold) }) ?? true else { throw WorkerError.response }
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
          var lines: [TranscriptLine] = []
          for (i, segment) in meta.segments.enumerated() {
            // 不开会时系统声音只用来去掉麦克风录到的回声：只转写和麦克风段重叠的部分，结果不写进记录。
            if !meeting && segment.track == .sys && !WorkerLogic.overlapsMic(segment, meta.segments) { continue }
            let recognition = try inference().transcribe(audio(segment, meta))
            let text = recognition.text
            if !text.isEmpty { lines.append(TranscriptLine(segment: segment, local: WorkerLogic.majority(cache.windows.filter { $0.segment == i }), text: text, confidence: recognition.confidence)) }
          }
          let labels = Dictionary(uniqueKeysWithValues: cache.hub.map { ($0.local, $0.is_me ? "我" : $0.label) })
          let ids = Dictionary(uniqueKeysWithValues: cache.hub.map { ($0.local, $0.speaker_id) })
          let record = WorkerLogic.record(meta: meta, device: device, lines: WorkerLogic.removeEcho(lines).filter { meeting || $0.segment.track == .mic }, labels: labels, ids: ids, retention: sync.retention_days)
          guard (record["body"] as! String).unicodeScalars.count <= 200000 else { throw WorkerError.recordTooLarge }
          let result = try JSONDecoder().decode(IngestResponse.self, from: await post("/v1/ingest", ["device": device, "records": [record]]))
          guard result.rejected.isEmpty, result.accepted + result.duplicates == 1 else { throw WorkerError.response }
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
        let candidates = meta.segments.indices.filter { i in cache.windows.contains { $0.segment == i && $0.local == request.local } }
          .sorted { meta.segments[$0].dbfs > meta.segments[$1].dbfs }
        var best: (segment: Int, range: Range<Int>, dbfs: Double)?
        // 先按整段响度排，最多解码前 3 段找最响的连续窗口。
        for i in candidates.prefix(3) {
          let samples = try audio(meta.segments[i], meta)
          let runs = WorkerLogic.runs(cache.windows.filter { $0.segment == i && $0.local == request.local })
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
