import AudioToolbox
import Foundation

/// C 接口返回 OSStatus，不经过 AVFAudio 的 ObjC 异常路径。
public enum PCMConversion {
  public static func monoFormat(rate: Double) throws -> AudioStreamBasicDescription {
    guard rate.isFinite, (8000...384000).contains(rate) else { throw PCMInputError.format }
    return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
      mBitsPerChannel: 32, mReserved: 0)
  }
}

/// 输入指针仅在 FillComplexBuffer 的同步调用期间有效。
public struct PCMConversionInput {
  public var samples: UnsafeBufferPointer<Float>
  public var offset = 0
  public var exhaustedStatus: OSStatus
  public init(samples: UnsafeBufferPointer<Float>, exhaustedStatus: OSStatus = noErr) {
    self.samples = samples; self.exhaustedStatus = exhaustedStatus
  }
}

public let supplyPCMInput: AudioConverterComplexInputDataProc = { _, packets, data, descriptions, context in
  guard let context else { return kAudio_ParamError }
  let input = context.assumingMemoryBound(to: PCMConversionInput.self)
  let count = min(Int(packets.pointee), input.pointee.samples.count - input.pointee.offset)
  packets.pointee = UInt32(count)
  data.pointee.mNumberBuffers = 1
  data.pointee.mBuffers.mNumberChannels = 1
  data.pointee.mBuffers.mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
  data.pointee.mBuffers.mData = count == 0 ? nil : UnsafeMutableRawPointer(mutating: input.pointee.samples.baseAddress! + input.pointee.offset)
  descriptions?.pointee = nil
  input.pointee.offset += count
  return count == 0 ? input.pointee.exhaustedStatus : noErr
}

public final class PCMResampler {
  private let converter: AudioConverterRef
  private var chunk = [Float](repeating: 0, count: 4096)
  // 与系统错误码分开；表示本批数据已用完，但流尚未结束。
  private static let needsInput: OSStatus = 0x72616e64
  public init(rate: Double) throws {
    var input = try PCMConversion.monoFormat(rate: rate)
    var output = try PCMConversion.monoFormat(rate: 16000)
    var converter: AudioConverterRef?
    let status = AudioConverterNew(&input, &output, &converter)
    guard status == noErr, let converter else { throw AudioError.codec(status) }
    self.converter = converter
  }
  deinit { AudioConverterDispose(converter) }

  public func convert(_ samples: [Float]) throws -> [Float] {
    guard !samples.isEmpty, samples.count <= Int(UInt32.max) / 4 else { throw PCMInputError.buffers }
    return try samples.withUnsafeBufferPointer { samples in
      var input = PCMConversionInput(samples: samples, exhaustedStatus: Self.needsInput)
      var result: [Float] = []
      while true {
        var count: UInt32 = UInt32(chunk.count)
        let status = chunk.withUnsafeMutableBytes { bytes in
          var list = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
          return AudioConverterFillComplexBuffer(converter, supplyPCMInput, &input, &count, &list, nil)
        }
        guard status == noErr || status == Self.needsInput else { throw AudioError.codec(status) }
        result.append(contentsOf: chunk.prefix(Int(count)))
        if status == Self.needsInput || count == 0 { break }
      }
      return result
    }
  }
}
