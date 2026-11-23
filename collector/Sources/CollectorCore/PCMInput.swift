import AudioToolbox
import Foundation

public enum PCMInputError: Error { case format, buffers }

/// 只解码明确描述的本机小端 PCM；不猜测设备实际格式。
public struct PCMInputFormat {
  public let rate: Double
  public let channels: Int
  public let bytesPerSample: Int
  public let planar: Bool
  private let floating: Bool

  public init(_ value: AudioStreamBasicDescription) throws {
    let flags = value.mFormatFlags
    let floating = flags & kAudioFormatFlagIsFloat != 0
    let bits = Int(value.mBitsPerChannel)
    let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
    let channels = Int(value.mChannelsPerFrame)
    guard value.mFormatID == kAudioFormatLinearPCM,
          flags & kAudioFormatFlagIsBigEndian == 0,
          flags & kAudioFormatFlagIsPacked != 0,
          (floating && (bits == 32 || bits == 64)) || (!floating && flags & kAudioFormatFlagIsSignedInteger != 0 && [16, 32].contains(bits)),
          value.mSampleRate.isFinite, (8000...384000).contains(value.mSampleRate),
          channels > 0, channels <= 256, value.mFramesPerPacket == 1,
          Int(value.mBytesPerFrame) == bits / 8 * (planar ? 1 : channels),
          value.mBytesPerPacket == value.mBytesPerFrame else { throw PCMInputError.format }
    rate = value.mSampleRate; self.channels = channels; bytesPerSample = bits / 8
    self.planar = planar; self.floating = floating
  }

  private func sample(_ bytes: UnsafeRawBufferPointer, _ index: Int) -> Float {
    let offset = index * bytesPerSample
    if floating {
      return bytesPerSample == 4 ? bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
        : Float(bytes.loadUnaligned(fromByteOffset: offset, as: Double.self))
    }
    return bytesPerSample == 2 ? Float(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32768
      : Float(bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2147483648
  }

  /// 多个输入流必须同采样率；每个平面/交错缓冲的帧数必须相同。
  public static func downmix(formats: [Self], buffers: [PCMInputBuffer]) throws -> [Float] {
    guard let first = formats.first, formats.allSatisfy({ $0.rate == first.rate }) else { throw PCMInputError.format }
    let layouts = formats.flatMap { format in
      Array(repeating: format, count: format.planar ? format.channels : 1)
    }
    guard buffers.count == layouts.count else { throw PCMInputError.buffers }
    var frames: Int?
    let channels = formats.reduce(0) { $0 + $1.channels }
    for (buffer, format) in zip(buffers, layouts) {
      let expected = format.planar ? 1 : format.channels
      let stride = expected * format.bytesPerSample
      guard buffer.channels == expected, buffer.bytes.count % stride == 0 else { throw PCMInputError.buffers }
      let count = buffer.bytes.count / stride
      guard frames == nil || frames == count else { throw PCMInputError.buffers }
      frames = count
    }
    var mono = [Float](repeating: 0, count: frames ?? 0)
    guard !mono.isEmpty else { return mono }
    let scale = 1.0 / Float(channels)
    for (buffer, format) in zip(buffers, layouts) {
      if format.floating && format.bytesPerSample == 4 {
        let raw = buffer.bytes.assumingMemoryBound(to: Float.self)
        let ch = buffer.channels
        if ch == 1 && channels == 1 {
          for i in 0..<mono.count {
            let sample = raw[i]
            guard sample.isFinite else { throw PCMInputError.buffers }
            mono[i] = sample
          }
        } else {
          for i in 0..<mono.count {
            var sum: Float = 0
            let base = i * ch
            for channel in 0..<ch {
              let sample = raw[base + channel]
              guard sample.isFinite else { throw PCMInputError.buffers }
              sum += sample
            }
            mono[i] += sum * scale
          }
        }
        continue
      }
      for i in mono.indices {
        for channel in 0..<buffer.channels {
          let sample = format.sample(buffer.bytes, i * buffer.channels + channel)
          guard sample.isFinite else { throw PCMInputError.buffers }
          mono[i] += sample * scale
        }
      }
    }
    return mono
  }
}

public struct PCMInputBuffer {
  public let channels: Int
  public let bytes: UnsafeRawBufferPointer
  public init(channels: Int, bytes: UnsafeRawBufferPointer) { self.channels = channels; self.bytes = bytes }
}

/// 将 10ms 级的小块 PCM 合并成约 512ms（16 个 32ms Silero VAD 窗口）再派发：
/// 减少高频线程唤醒、重采样分配和冷缓存推理，不跳过任何人声。
public struct PCMBatcher {
  public let targetDuration: Double
  public let maxDiscontinuity: Double
  public let maxTrailingSilence: Double
  private var buffer: [Float] = []
  private var rate: Double = 0
  private var startHost: UInt64?
  private var expectedNextHost: UInt64?
  private var hasSeenAudio = false
  private var trailingSilenceFrames = 0

  public init(targetDuration: Double = 0.512, maxDiscontinuity: Double = 0.15, maxTrailingSilence: Double = 1.0) {
    self.targetDuration = targetDuration
    self.maxDiscontinuity = maxDiscontinuity
    self.maxTrailingSilence = maxTrailingSilence
  }

  public mutating func append(_ samples: [Float], rate: Double, host: UInt64, ticksPerSecond: Double,
                              emit: ([Float], Double, UInt64) -> Void) {
    guard !samples.isEmpty, rate > 0, ticksPerSecond > 0 else { return }
    hasSeenAudio = true
    trailingSilenceFrames = 0
    appendRaw(samples, rate: rate, host: host, ticksPerSecond: ticksPerSecond, emit: emit)
  }

  /// 全零静音回调（如系统无播放）：在最后一次非零声音之后最多再送 maxTrailingSilence 秒静音让 VAD 正常收尾，
  /// 之后直接跳过分配与派发；有新声音到来时由时间戳跳变自动重建流。
  public mutating func appendZeroFrames(count: Int, rate: Double, host: UInt64, ticksPerSecond: Double,
                                        emit: ([Float], Double, UInt64) -> Void) {
    guard count > 0, rate > 0, ticksPerSecond > 0 else { return }
    let limit = Int((rate * maxTrailingSilence).rounded(.up))
    guard hasSeenAudio else { return }
    if trailingSilenceFrames >= limit {
      flush(emit: emit)
      return
    }
    let keep = min(count, limit - trailingSilenceFrames)
    trailingSilenceFrames += keep
    appendRaw([Float](repeating: 0, count: keep), rate: rate, host: host, ticksPerSecond: ticksPerSecond, emit: emit)
    if trailingSilenceFrames >= limit { flush(emit: emit) }
  }

  public mutating func flush(emit: ([Float], Double, UInt64) -> Void) {
    guard !buffer.isEmpty, let host = startHost, rate > 0 else {
      buffer.removeAll(keepingCapacity: true); startHost = nil; expectedNextHost = nil
      return
    }
    let out = buffer
    let outRate = rate
    buffer = []
    buffer.reserveCapacity(targetFrames(for: outRate))
    startHost = nil
    expectedNextHost = nil
    emit(out, outRate, host)
  }

  private func targetFrames(for rate: Double) -> Int {
    max(1, Int((rate * targetDuration).rounded()))
  }

  private mutating func appendRaw(_ samples: [Float], rate: Double, host: UInt64, ticksPerSecond: Double,
                                  emit: ([Float], Double, UInt64) -> Void) {
    if !buffer.isEmpty {
      let discontinuity: Bool
      if self.rate != rate {
        discontinuity = true
      } else if let expected = expectedNextHost {
        let delta = host >= expected ? Double(host - expected) : Double(expected - host)
        discontinuity = delta / ticksPerSecond > maxDiscontinuity
      } else {
        discontinuity = false
      }
      if discontinuity { flush(emit: emit) }
    }
    if buffer.isEmpty {
      self.rate = rate
      startHost = host
      let target = targetFrames(for: rate)
      if buffer.capacity < target { buffer.reserveCapacity(target) }
    }
    buffer.append(contentsOf: samples)
    let durationTicks = UInt64((Double(samples.count) / rate * ticksPerSecond).rounded())
    expectedNextHost = host &+ durationTicks
    if buffer.count >= targetFrames(for: rate) {
      flush(emit: emit)
    }
  }
}
