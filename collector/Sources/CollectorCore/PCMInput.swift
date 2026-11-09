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
    for (buffer, format) in zip(buffers, layouts) {
      for i in mono.indices {
        for channel in 0..<buffer.channels {
          let sample = format.sample(buffer.bytes, i * buffer.channels + channel)
          guard sample.isFinite else { throw PCMInputError.buffers }
          mono[i] += sample / Float(channels)
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
