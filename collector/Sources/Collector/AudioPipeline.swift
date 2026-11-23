import Foundation
import Darwin
import CSherpa
import CollectorCore

/// 每路一个重采样器和 VAD；只加载 Silero，不加载转写或声纹模型。
final class AudioPipeline {
  let vad: OpaquePointer
  let model: UnsafeMutablePointer<CChar>
  let provider = strdup("cpu")!
  var converter: PCMResampler?
  var rate = 0.0
  var origin: Date?
  var nextTime: Date?
  var pending: [Float] = []
  var speechActive = false
  var skippedSilence = false
  let emit: ([Float], Date, Date) throws -> Void
  let level: (Double, Date, Date) -> Void

  init(modelPath: String, emit: @escaping ([Float], Date, Date) throws -> Void, level: @escaping (Double, Date, Date) -> Void) throws {
    self.model = strdup(modelPath)!; self.emit = emit; self.level = level
    var config = SherpaOnnxVadModelConfig()
    config.sample_rate = 16000; config.num_threads = 1; config.provider = UnsafePointer(provider)
    config.silero_vad.model = UnsafePointer(model)
    config.silero_vad.threshold = 0.5; config.silero_vad.min_silence_duration = 0.5
    config.silero_vad.min_speech_duration = 0.25; config.silero_vad.window_size = 512
    config.silero_vad.max_speech_duration = 20
    guard let vad = SherpaOnnxCreateVoiceActivityDetector(&config, 30) else {
      free(model); free(provider); throw AudioCaptureError("语音模型加载失败，请关闭录音再打开重试")
    }
    self.vad = vad
  }
  deinit { SherpaOnnxDestroyVoiceActivityDetector(vad); free(model); free(provider) }

  private static let secondsPerTick: Double? = {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return nil }
    return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
  }()

  func accept(_ samples: [Float], rate: Double, host: UInt64) throws {
    guard !samples.isEmpty else { return }
    guard rate.isFinite, (8000...384000).contains(rate), samples.count <= Int(UInt32.max) / 4 else {
      throw AudioCaptureError("音频采样率或帧数不可用")
    }
    guard let secondsPerTick = Self.secondsPerTick else { throw AudioCaptureError("无法读取 hostTime 时基") }
    let seconds = Double(host) * secondsPerTick
    let start = Date().addingTimeInterval(seconds - ProcessInfo.processInfo.systemUptime)
    let end = start.addingTimeInterval(Double(samples.count) / rate)
    level(Self.dbfs(samples), start, end)
    // 整段都是数字静音（系统没在放声音、麦克风被静音）时不重采样、不跑 VAD：零采样里不可能有人声，
    // 两路一直跑 VAD 是采集端空闲时 CPU 的大头。跳过过的话，下一段有声音时重建流、从这一段重新计时，
    // 否则 VAD 按喂进去的采样数算时间，跳过的那段会让之后的时间戳整体提前。
    if !speechActive, samples.allSatisfy({ $0 == 0 }) { skippedSilence = true; return }
    // 丢帧或设备格式变化时重建流，避免错误的时间戳持续累积。
    if self.rate != rate || skippedSilence || nextTime.map({ abs(start.timeIntervalSince($0)) > 0.2 }) == true {
      skippedSilence = false
      try flush(); SherpaOnnxVoiceActivityDetectorReset(vad); origin = nil; pending = []
      self.rate = rate
      converter = try PCMResampler(rate: rate)
    }
    nextTime = end
    if origin == nil { origin = start }
    guard let converter else { throw AudioCaptureError("音频重采样器未初始化") }
    pending.append(contentsOf: try converter.convert(samples))
    var offset = 0
    while pending.count - offset >= 512 {
      pending.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress! + offset, 512) }
      offset += 512; try drain()
    }
    pending.removeFirst(offset)
    speechActive = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
  }
  func flush() throws {
    if !pending.isEmpty {
      pending.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
      pending = []
    }
    SherpaOnnxVoiceActivityDetectorFlush(vad); try drain(); speechActive = false
  }
  private func drain() throws {
    while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
      guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad), let origin else { throw AudioCaptureError("VAD 人声段读取失败") }
      defer { SherpaOnnxDestroySpeechSegment(segment); SherpaOnnxVoiceActivityDetectorPop(vad) }
      let audio = Array(UnsafeBufferPointer(start: segment.pointee.samples, count: Int(segment.pointee.n)))
      let start = origin.addingTimeInterval(Double(segment.pointee.start) / 16000)
      try emit(audio, start, start.addingTimeInterval(Double(audio.count) / 16000))
    }
  }
  static func dbfs(_ samples: [Float]) -> Double {
    let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
    return 10 * log10(max(1e-16, power))
  }
}
