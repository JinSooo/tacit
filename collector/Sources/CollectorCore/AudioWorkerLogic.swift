import Foundation

public struct VoiceWindow: Codable, Equatable {
  public var segment: Int
  public var offset: Int
  public var count: Int
  public var local: String
  public init(segment: Int, offset: Int, count: Int, local: String = "") {
    self.segment = segment; self.offset = offset; self.count = count; self.local = local
  }
}
public struct LocalSpeaker: Codable {
  public var local: String
  public var track: AudioTrack
  public var seconds: Double
  public var centroid: [Float]
  public var weightedSum: [Double]
}
public struct TranscriptLine {
  public var segment: AudioSegment
  public var local: String
  public var text: String
  public var confidence: Double?
  public init(segment: AudioSegment, local: String, text: String, confidence: Double? = nil) {
    self.segment = segment; self.local = local; self.text = text; self.confidence = confidence
  }
}
public enum WorkerLogic {
  public static func windows(count: Int, segment: Int) -> [VoiceWindow] {
    guard count >= 24000 else { return [] }
    return stride(from: 0, to: count, by: 48000).compactMap {
      let n = min(48000, count - $0)
      return n >= 24000 ? VoiceWindow(segment: segment, offset: $0, count: n) : nil
    }
  }
  /// 系统 AAC 编码器固定在开头加 2112 个采样的空白（实测），末尾只补到 1024 的整数倍。
  /// 不按段的时间戳推算：时间戳只精确到秒，推算会截掉段首最多约 1 秒人声，短段会被截空。
  public static let aacPriming = 2112
  public static func trimPadding(_ samples: [Float]) -> [Float] {
    Array(samples.dropFirst(aacPriming))
  }
  public static func unit(_ vector: [Float]) -> [Float] {
    let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
    guard norm.isFinite, norm > 0 else { return [] }
    return vector.map { Float(Double($0) / norm) }
  }
  public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    return zip(unit(a), unit(b)).reduce(0) { $0 + Double($1.0) * Double($1.1) }
  }
  // 不跨路合并，确保 mic 判定只使用 mic 的中心；输入始终按时间、track、file、窗口偏移排序。
  public static func assign(vector: [Float], track: AudioTrack, seconds: Double, speakers: inout [LocalSpeaker]) -> String {
    let v = unit(vector)
    let best = speakers.indices.filter { speakers[$0].track == track }.max {
      let a = cosine(speakers[$0].centroid, v), b = cosine(speakers[$1].centroid, v)
      return a == b ? $0 > $1 : a < b
    }
    if let i = best, cosine(speakers[i].centroid, v) >= 0.6 {
      let old = speakers[i]
      speakers[i].weightedSum = zip(old.weightedSum, v).map { $0 + Double($1) * seconds }
      speakers[i].centroid = unit(speakers[i].weightedSum.map(Float.init))
      speakers[i].seconds += seconds
      return old.local
    }
    let local = "S\(speakers.count + 1)"
    speakers.append(LocalSpeaker(local: local, track: track, seconds: seconds, centroid: v, weightedSum: v.map { Double($0) * seconds }))
    return local
  }
  /// 同一段里首尾相接的窗口合成一个整段，供试听片段挑选。
  public static func runs(_ windows: [VoiceWindow]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    for w in windows.sorted(by: { $0.offset < $1.offset }) {
      if let last = ranges.last, last.upperBound == w.offset { ranges[ranges.count - 1] = last.lowerBound..<(w.offset + w.count) }
      else { ranges.append(w.offset..<(w.offset + w.count)) }
    }
    return ranges
  }

  /// 均方根响度（dBFS）。用户报告：远处、隔墙的细微声音反而被选成试听片段。
  public static func dbfs(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return -.infinity }
    let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
    return power > 0 ? 10 * log10(power) : -.infinity
  }

  /// 在连续片段里挑最响的一段，每段最多 `limit` 个采样。很长的一段先滑窗找最响的位置，
  /// 避免整段前一半是静音时把静音当成片段开头。响度相近（差不到 1 dB）时留更长的。
  public static func loudest(_ ranges: [Range<Int>], in samples: [Float], limit: Int) -> (range: Range<Int>, dbfs: Double)? {
    var best: (range: Range<Int>, dbfs: Double)?
    for r in ranges.sorted(by: { $0.count > $1.count }) {
      let lo = max(0, r.lowerBound), hi = min(samples.count, r.upperBound)
      guard hi > lo else { continue }
      let width = min(limit, hi - lo), hop = max(1, width / 2)
      var start = lo
      while start < hi {
        let end = min(hi, start + width)
        let level = dbfs(samples[start..<end])
        if best == nil || level > best!.dbfs + 1 { best = (start..<end, level) }
        if end == hi { break }
        start += hop
      }
    }
    return best
  }

  /// 试听片段把峰值提到能听清的音量：最多放大 16 倍（约 24 dB），已经够响的不动，避免爆音。
  public static func normalize(_ samples: [Float], target: Float = 0.7, maxGain: Float = 16) -> [Float] {
    let peak = samples.reduce(0 as Float) { Swift.max($0, abs($1)) }
    guard peak.isFinite, peak > 0 else { return samples }
    let gain = Swift.min(maxGain, target / peak)
    guard gain > 1 else { return samples }
    return samples.map { Swift.max(-1, Swift.min(1, $0 * gain)) }
  }

  public static func majority(_ windows: [VoiceWindow]) -> String {
    let counts = Dictionary(grouping: windows, by: \.local).mapValues(\.count)
    return counts.keys.sorted().max { counts[$0]! == counts[$1]! ? $0 > $1 : counts[$0]! < counts[$1]! } ?? ""
  }
  public static func decision(speakers: [LocalSpeaker], voiceprint: [Float]?, threshold: Double, meetings: [String]) -> AudioStatus {
    guard let voiceprint else { return .waiting_me }
    return !meetings.isEmpty || speakers.contains { $0.track == .mic && cosine($0.centroid, voiceprint) >= threshold } ? .done : .skipped
  }
  public static func similarity(_ lhs: String, _ rhs: String) -> Double {
    let a = Array(lhs), b = Array(rhs)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var row = Array(0...b.count)
    for (i, x) in a.enumerated() {
      var next = [i + 1] + Array(repeating: 0, count: b.count)
      for (j, y) in b.enumerated() { next[j+1] = min(next[j] + 1, row[j+1] + 1, row[j] + (x == y ? 0 : 1)) }
      row = next
    }
    return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
  }
  public static func overlapsMic(_ segment: AudioSegment, _ all: [AudioSegment]) -> Bool {
    all.contains { $0.track == .mic && AudioPolicy.date($0.t_start)! < AudioPolicy.date(segment.t_end)! && AudioPolicy.date(segment.t_start)! < AudioPolicy.date($0.t_end)! }
  }
  public static func removeEcho(_ lines: [TranscriptLine]) -> [TranscriptLine] {
    lines.filter { mic in
      guard mic.segment.track == .mic else { return true }
      return !lines.contains { sys in
        sys.segment.track == .sys && AudioPolicy.date(mic.segment.t_start)! < AudioPolicy.date(sys.segment.t_end)! &&
        AudioPolicy.date(sys.segment.t_start)! < AudioPolicy.date(mic.segment.t_end)! && similarity(mic.text, sys.text) >= 0.6
      }
    }.sorted { AudioPolicy.date($0.segment.t_start)! < AudioPolicy.date($1.segment.t_start)! }
  }
  public static func clock(_ text: String, seconds: Bool) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return f.string(from: AudioPolicy.date(text)!)
  }
  public static func record(meta: AudioMetadata, device: String, lines: [TranscriptLine], labels: [String: String], ids: [String: String], retention: Int) -> [String: Any] {
    let lines = lines.sorted {
      let a = AudioPolicy.date($0.segment.t_start)!, b = AudioPolicy.date($1.segment.t_start)!
      return a == b ? $0.segment.file < $1.segment.file : a < b
    }
    let used = Array(Set(lines.map(\.local))).sorted()
    // 同一人在对话内可能被拆成多个本地标签，标题按名字去重。
    var seen = Set<String>()
    let names = used.map { labels[$0] ?? ($0.isEmpty ? "未知说话人" : $0) }.filter { seen.insert($0).inserted }.joined(separator: "、")
    let title = "对话 · \(clock(meta.t_start, seconds: false))–\(clock(meta.t_end!, seconds: false)) · \(names)"
    let body = lines.map { "[\(clock($0.segment.t_start, seconds: true))] \(labels[$0.local] ?? "未知说话人")：\($0.text)" }.joined(separator: "\n")
    func dbfs(_ track: AudioTrack) -> Any {
      let segments = meta.segments.filter { $0.track == track }
      return segments.isEmpty ? NSNull() : segments.reduce(0.0) { $0 + $1.dbfs } / Double(segments.count) as Any
    }
    var capture: [String: Any] = ["method": "asr"]
    // C API 有概率时按段平均；模型未返回概率时省略可选字段，不伪造置信度。
    let confidences = lines.compactMap(\.confidence)
    if confidences.count == lines.count && !confidences.isEmpty {
      capture["confidence"] = confidences.reduce(0, +) / Double(confidences.count)
    }
    return ["id": ULID.make(), "schema": 1, "device": device, "source": "mac.audio", "source_ref": meta.id,
      "kind": "span", "t_start": meta.t_start, "t_end": meta.t_end!, "title": String(Text.clamp(title, 200).unicodeScalars.prefix(200)),
      "body": body, "people": Array(Set(used.compactMap { ids[$0] })).sorted(), "sensitivity": "normal",
      "capture": capture,
      "context": ["app": meta.meeting_apps.first as Any? ?? NSNull(), "extra": [
        "speech_seconds": meta.segments.reduce(0.0) { $0 + AudioPolicy.date($1.t_end)!.timeIntervalSince(AudioPolicy.date($1.t_start)!) },
        "mic_dbfs": dbfs(.mic), "sys_dbfs": dbfs(.sys), "tracks": Array(Set(meta.segments.map { $0.track.rawValue })).sorted()]],
      "media": [["path": "audio/\(meta.t_start.prefix(10))/\(meta.id)", "kind": "audio", "expires": LocalTime.iso(AudioPolicy.date(meta.t_end)!.addingTimeInterval(Double(retention) * 86400))]]]
  }
  public static func wav(_ samples: [Float]) -> Data {
    var data = Data()
    func text(_ s: String) { data.append(contentsOf: s.utf8) }
    func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    text("RIFF"); u32(UInt32(36 + samples.count * 2)); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    text("data"); u32(UInt32(samples.count * 2))
    for s in samples { u16(UInt16(bitPattern: Int16((max(-1, min(1, s)) * 32767).rounded()))) }
    return data
  }
}
