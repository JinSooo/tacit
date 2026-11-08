import Foundation
import AVFoundation
import AudioToolbox
import CollectorCore

/// 内存中的 16kHz 单声道 AAC/ADTS；加密前不产生任何明文文件。
public enum AudioCodec {
  public static var encoderAvailable: Bool {
    let input = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])!
    return AVAudioConverter(from: input, to: output) != nil
  }
  public static func encode(_ samples: [Float]) throws -> Data {
    guard !samples.isEmpty else { return Data() }
    let input = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
      AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])!
    guard let converter = AVAudioConverter(from: input, to: output),
          let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)) else {
      var src = input.streamDescription.pointee, dst = output.streamDescription.pointee
      var probe: AudioConverterRef?
      let status = AudioConverterNew(&src, &dst, &probe)
      if let probe { AudioConverterDispose(probe) }
      throw AudioError.codec(status == noErr ? -1 : status)
    }
    pcm.frameLength = pcm.frameCapacity
    samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    var offset = 0, result = Data()
    while true {
      let encoded = AVAudioCompressedBuffer(format: output, packetCapacity: 32, maximumPacketSize: max(2048, converter.maximumOutputPacketSize))
      var error: NSError?
      let status = converter.convert(to: encoded, error: &error) { requested, state in
        guard offset < samples.count else { state.pointee = .endOfStream; return nil }
        let count = min(Int(requested), samples.count - offset)
        let chunk = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
        chunk.frameLength = chunk.frameCapacity
        chunk.floatChannelData![0].update(from: pcm.floatChannelData![0] + offset, count: count)
        offset += count; state.pointee = .haveData; return chunk
      }
      if let error { throw error }
      for i in 0..<Int(encoded.packetCount) {
        guard let descriptions = encoded.packetDescriptions else { throw AudioError.codec(-2) }
        let packet = descriptions[i], count = Int(packet.mDataByteSize), length = count + 7
        guard length < 8192 else { throw AudioError.codec(-3) }
        // AAC-LC，采样率索引 8（16kHz），单声道，一个 raw data block。
        result.append(contentsOf: [0xff, 0xf1, 0x60, UInt8(0x40 | (length >> 11)), UInt8((length >> 3) & 255), UInt8((length & 7) << 5 | 0x1f), 0xfc])
        result.append(encoded.data.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self), count: count)
      }
      if status == .endOfStream { break }
      if status == .error { throw AudioError.codec(-4) }
    }
    return result
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
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    var asbd = format.streamDescription.pointee
    try check(ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: asbd)), &asbd))
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var samples: [Float] = []
    while true {
      // frameLength 为 0 时 AudioBufferList 的 mDataByteSize 也是 0，ExtAudioFileRead 会一帧都读不到。
      buffer.frameLength = buffer.frameCapacity
      var count: UInt32 = buffer.frameCapacity
      try check(ExtAudioFileRead(extended, &count, buffer.mutableAudioBufferList))
      if count == 0 { break }
      samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(count)))
    }
    return samples
  }
  private static func check(_ status: OSStatus) throws { if status != noErr { throw AudioError.codec(status) } }
}
private final class AudioMemory {
  let data: Data
  init(_ data: Data) { self.data = data }
}
