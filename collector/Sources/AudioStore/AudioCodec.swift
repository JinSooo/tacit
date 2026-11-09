import Foundation
import AudioToolbox
import CollectorCore

/// 内存中的 16kHz 单声道 AAC/ADTS；加密前不产生任何明文文件。
public enum AudioCodec {
  private static func encoder() throws -> AudioConverterRef {
    var input = try PCMConversion.monoFormat(rate: 16000)
    var output = AudioStreamBasicDescription()
    output.mSampleRate = 16000; output.mFormatID = kAudioFormatMPEG4AAC; output.mChannelsPerFrame = 1
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output))
    var converter: AudioConverterRef?
    try check(AudioConverterNew(&input, &output, &converter))
    guard let converter else { throw AudioError.codec(-1) }
    do {
      var bitrate: UInt32 = 32000
      try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate))
      return converter
    } catch { AudioConverterDispose(converter); throw error }
  }
  public static var encoderAvailable: Bool {
    guard let converter = try? encoder() else { return false }
    AudioConverterDispose(converter); return true
  }
  public static func encode(_ samples: [Float]) throws -> Data {
    guard !samples.isEmpty else { return Data() }
    guard samples.count <= Int(UInt32.max) / 4, samples.allSatisfy({ $0.isFinite }) else { throw AudioError.codec(-2) }
    let converter = try encoder()
    defer { AudioConverterDispose(converter) }
    var maximum: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    try check(AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maximum))
    guard maximum > 0, maximum < 8192 else { throw AudioError.codec(-3) }
    return try samples.withUnsafeBufferPointer { samples in
      var input = PCMConversionInput(samples: samples)
      var result = Data()
      while true {
        var bytes = [UInt8](repeating: 0, count: Int(maximum))
        var packet = AudioStreamPacketDescription(), count: UInt32 = 1
        let status = bytes.withUnsafeMutableBytes { bytes in
          var list = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
          return AudioConverterFillComplexBuffer(converter, supplyPCMInput, &input, &count, &list, &packet)
        }
        try check(status)
        if count == 0 { break }
        let length = Int(packet.mDataByteSize) + 7, offset = Int(packet.mStartOffset)
        guard packet.mDataByteSize > 0, length < 8192, offset >= 0,
              offset + Int(packet.mDataByteSize) <= bytes.count else { throw AudioError.codec(-3) }
        // AAC-LC，采样率索引 8（16kHz），单声道，一个 raw data block。
        result.append(contentsOf: [0xff, 0xf1, 0x60, UInt8(0x40 | (length >> 11)), UInt8((length >> 3) & 255), UInt8((length & 7) << 5 | 0x1f), 0xfc])
        result.append(contentsOf: bytes[offset..<(offset + Int(packet.mDataByteSize))])
      }
      return result
    }
  }

  /// worker 可直接解码 readSegment 的返回值，不需要临时 .aac 文件。
  public static func decode(_ data: Data) throws -> [Float] {
    let memory = AudioMemory(data)
    let pointer = Unmanaged.passUnretained(memory).toOpaque()
    var file: AudioFileID?
    try check(AudioFileOpenWithCallbacks(pointer, { context, position, requested, buffer, actual in
      let memory = Unmanaged<AudioMemory>.fromOpaque(context).takeUnretainedValue()
      guard position >= 0, position <= memory.data.count else { actual.pointee = 0; return noErr }
      let count = min(Int(requested), memory.data.count - Int(position))
      memory.data.withUnsafeBytes { bytes in
        if count > 0 { buffer.copyMemory(from: bytes.baseAddress!.advanced(by: Int(position)), byteCount: count) }
      }
      actual.pointee = UInt32(count); return noErr
    }, nil, { context in Int64(Unmanaged<AudioMemory>.fromOpaque(context).takeUnretainedValue().data.count) }, nil, kAudioFileAAC_ADTSType, &file))
    guard let file else { throw AudioError.codec(-5) }
    defer { AudioFileClose(file) }
    var extended: ExtAudioFileRef?
    try check(ExtAudioFileWrapAudioFileID(file, false, &extended))
    guard let extended else { throw AudioError.codec(-6) }
    defer { ExtAudioFileDispose(extended); withExtendedLifetime(memory) {} }
    var asbd = try PCMConversion.monoFormat(rate: 16000)
    try check(ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: asbd)), &asbd))
    var samples: [Float] = []
    while true {
      var chunk = [Float](repeating: 0, count: 4096), count: UInt32 = 4096
      let status = chunk.withUnsafeMutableBytes { bytes in
        var list = AudioBufferList(mNumberBuffers: 1,
          mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        return ExtAudioFileRead(extended, &count, &list)
      }
      try check(status)
      if count == 0 { break }
      samples.append(contentsOf: chunk.prefix(Int(count)))
    }
    return samples
  }
  private static func check(_ status: OSStatus) throws { if status != noErr { throw AudioError.codec(status) } }
}
private final class AudioMemory {
  let data: Data
  init(_ data: Data) { self.data = data }
}
