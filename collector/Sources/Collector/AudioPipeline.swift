import Foundation
import AVFoundation
import CSherpa
import CollectorCore

/// 每路一个重采样器和 VAD；只加载 Silero，不加载转写或声纹模型。
final class AudioPipeline {
  let vad: OpaquePointer
  let model: UnsafeMutablePointer<CChar>
  let provider = strdup("cpu")!
  var converter: AVAudioConverter?
  var rate = 0.0
  var origin: Date?
  var nextTime: Date?
  var pending: [Float] = []
  var speechActive = false
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
      free(model); free(provider); throw AudioCaptureError("语音模型加载失败，请重新运行 ./install.sh")
    }
    self.vad = vad
  }
  deinit { SherpaOnnxDestroyVoiceActivityDetector(vad); free(model); free(provider) }

  func accept(_ samples: [Float], rate: Double, host: UInt64) throws {
    guard !samples.isEmpty, rate > 0 else { return }
    let start = Date().addingTimeInterval(AVAudioTime.seconds(forHostTime: host) - ProcessInfo.processInfo.systemUptime)
    let end = start.addingTimeInterval(Double(samples.count) / rate)
    level(Self.dbfs(samples), start, end)
    // 丢帧或设备格式变化时重建流，避免错误的时间戳持续累积。
    if self.rate != rate || nextTime.map({ abs(start.timeIntervalSince($0)) > 0.2 }) == true {
      try flush(); SherpaOnnxVoiceActivityDetectorReset(vad); origin = nil; pending = []
      self.rate = rate
      let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
      converter = AVAudioConverter(from: input, to: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!)
      guard converter != nil else { throw AudioCaptureError("音频重采样器创建失败") }
    }
    nextTime = end
    if origin == nil { origin = start }
    let input = AVAudioPCMBuffer(pcmFormat: converter!.inputFormat, frameCapacity: AVAudioFrameCount(samples.count))!
    input.frameLength = input.frameCapacity
    samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    let output = AVAudioPCMBuffer(pcmFormat: converter!.outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16000 / rate) + 64))!
    var supplied = false, error: NSError?
    let status = converter!.convert(to: output, error: &error) { _, state in
      if supplied { state.pointee = .noDataNow; return nil }
      supplied = true; state.pointee = .haveData; return input
    }
    if let error { throw error }
    guard status != .error else { throw AudioCaptureError("音频重采样失败") }
    pending.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
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
