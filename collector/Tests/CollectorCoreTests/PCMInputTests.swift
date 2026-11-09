import AudioToolbox
import Foundation
import Testing
@testable import CollectorCore

private func format(_ rate: Double, _ channels: UInt32, planar: Bool = false, integer: Bool = false) -> AudioStreamBasicDescription {
  let bytes: UInt32 = integer ? 2 : 4
  return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: (integer ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat) | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
    mBytesPerPacket: bytes * (planar ? 1 : channels), mFramesPerPacket: 1,
    mBytesPerFrame: bytes * (planar ? 1 : channels), mChannelsPerFrame: channels,
    mBitsPerChannel: bytes * 8, mReserved: 0)
}

@Test func microphoneDeviceFormatsDoNotReuseBluetoothRate() throws {
  for rate in [16000.0, 48000.0] {
    for channels: UInt32 in [1, 2] {
      let parsed = try PCMInputFormat(format(rate, channels))
      #expect(parsed.rate == rate)
      #expect(parsed.channels == Int(channels))
      let values: [Float] = channels == 1 ? [0.25, -0.5] : [0.5, 0, -1, 0]
      let result = try values.withUnsafeBytes {
        try PCMInputFormat.downmix(formats: [parsed], buffers: [PCMInputBuffer(channels: Int(channels), bytes: $0)])
      }
      #expect(result == [0.25, -0.5])
    }
  }
}

@Test func microphonePlanarAndIntegerDownmix() throws {
  let parsed = try PCMInputFormat(format(48000, 2, planar: true))
  let left: [Float] = [1, -1], right: [Float] = [0, 0.5]
  let mono = try left.withUnsafeBytes { l in
    try right.withUnsafeBytes { r in
      try PCMInputFormat.downmix(formats: [parsed], buffers: [.init(channels: 1, bytes: l), .init(channels: 1, bytes: r)])
    }
  }
  #expect(mono == [0.5, -0.25])
  let pcm = try PCMInputFormat(format(16000, 2, integer: true))
  let ints: [Int16] = [16384, 0, -16384, 0]
  #expect(try ints.withUnsafeBytes { try PCMInputFormat.downmix(formats: [pcm], buffers: [.init(channels: 2, bytes: $0)]) } == [0.25, -0.25])
}

@Test func malformedMicrophoneFormatsAndBuffersAreRejected() throws {
  for rate in [0, Double.nan, Double.infinity, 1e100] {
    #expect(throws: PCMInputError.self) { try PCMInputFormat(format(rate, 1)) }
  }
  var invalid = format(48000, 2)
  invalid.mBytesPerFrame = 4
  #expect(throws: PCMInputError.self) { try PCMInputFormat(invalid) }
  invalid = format(48000, 1); invalid.mFormatID = kAudioFormatMPEG4AAC
  #expect(throws: PCMInputError.self) { try PCMInputFormat(invalid) }
  let stereo = try PCMInputFormat(format(48000, 2)), planar = try PCMInputFormat(format(48000, 2, planar: true))
  let bytes: [Float] = [1, 0, 1]
  bytes.withUnsafeBytes { b in
    #expect(throws: PCMInputError.self) { try PCMInputFormat.downmix(formats: [stereo], buffers: [.init(channels: 2, bytes: b)]) }
    #expect(throws: PCMInputError.self) { try PCMInputFormat.downmix(formats: [planar], buffers: [.init(channels: 1, bytes: b)]) }
  }
  let nan: [Float] = [.nan]
  let mono = try PCMInputFormat(format(16000, 1))
  _ = nan.withUnsafeBytes { b in
    #expect(throws: PCMInputError.self) { try PCMInputFormat.downmix(formats: [mono], buffers: [.init(channels: 1, bytes: b)]) }
  }
}

@Test func multipleInputStreamsRequireMatchingRatesAndFrames() throws {
  let a = try PCMInputFormat(format(16000, 1)), b = try PCMInputFormat(format(48000, 1))
  let values: [Float] = [0.5, -0.5]
  try values.withUnsafeBytes { bytes in
    let buffer = PCMInputBuffer(channels: 1, bytes: bytes)
    let mixed = try PCMInputFormat.downmix(formats: [a, a], buffers: [buffer, buffer])
    #expect(mixed == values)
    #expect(throws: PCMInputError.self) { try PCMInputFormat.downmix(formats: [a, b], buffers: [buffer, buffer]) }
    let short = PCMInputBuffer(channels: 1, bytes: UnsafeRawBufferPointer(rebasing: bytes.prefix(4)))
    #expect(throws: PCMInputError.self) { try PCMInputFormat.downmix(formats: [a, a], buffers: [buffer, short]) }
  }
}

@Test func fixedMicrophoneNeverReadsSystemDefaultID() {
  let devices = [MicrophoneDevice(uid: "builtin-test", name: "自带", isBuiltIn: true),
                 MicrophoneDevice(uid: "headset-test", name: "耳机", isBuiltIn: false)]
  var reads = 0
  let systemDefault = { reads += 1; return UInt32(16) as UInt32? }
  let ids: [String: UInt32] = ["builtin-test": 48, "headset-test": 16]
  #expect(MicrophoneSelection.resolve(devices: devices).inputID(devices: ids, defaultInput: systemDefault) == 48)
  #expect(MicrophoneSelection.resolve(devices: devices, setting: "headset-test").inputID(devices: ids, defaultInput: systemDefault) == 16)
  #expect(MicrophoneSelection.resolve(devices: devices, setting: "disconnected").inputID(devices: ids, defaultInput: systemDefault) == 48)
  #expect(MicrophoneSelection.resolve(devices: []).inputID(devices: ids, defaultInput: systemDefault) == nil)
  #expect(reads == 0)
  #expect(MicrophoneSelection.system.inputID(devices: ids, defaultInput: systemDefault) == 16)
  #expect(reads == 1)
  #expect(MicrophoneSelection.system.inputID(devices: ids, defaultInput: { 0 }) == nil)
}

@Test func recordingStartupCrashPausesUntilManualRetry() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let first = RecordingStartGuard(dataDirectory: dir)
  #expect(!first.blocked)
  try first.begin()
  let restarted = RecordingStartGuard(dataDirectory: dir)
  #expect(restarted.blocked)
  #expect(throws: CocoaError.self) { try restarted.begin() }
  #expect(RecordingStartGuard(dataDirectory: dir).blocked)
  try restarted.allowManualRetry()
  #expect(!restarted.blocked)
  try restarted.begin()
  #expect(RecordingStartGuard(dataDirectory: dir).blocked)
  try restarted.clear()
  #expect(!RecordingStartGuard(dataDirectory: dir).blocked)
  // 可处理的启动错误和正常成功一样清标记，不会被误判为进程崩溃。
  try restarted.begin(); try restarted.clear()
  #expect(!RecordingStartGuard(dataDirectory: dir).blocked)
}

@Test func pcmResamplingSupportsDeviceRatesAcrossChunks() throws {
  for rate in [16000.0, 48000.0] {
    let converter = try PCMResampler(rate: rate)
    var output: [Float] = []
    for _ in 0..<20 {
      output += try converter.convert([Float](repeating: 0.25, count: Int(rate / 10)))
    }
    #expect(abs(output.count - 32000) < 1024)
    #expect(output.allSatisfy { $0.isFinite })
    #expect(abs((output.dropFirst(512).reduce(0, +) / Float(output.count - 512)) - 0.25) < 0.01)
  }
  #expect(throws: PCMInputError.self) { try PCMResampler(rate: .nan) }
}

@Test func recordingStartupMarkerSpansNestedAttemptsAndClearsHandledErrors() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let guardrail = RecordingStartGuard(dataDirectory: dir)
  try guardrail.attempt {
    #expect(RecordingStartGuard(dataDirectory: dir).blocked)
    try guardrail.attempt { #expect(RecordingStartGuard(dataDirectory: dir).blocked) }
    #expect(RecordingStartGuard(dataDirectory: dir).blocked)
  }
  #expect(!RecordingStartGuard(dataDirectory: dir).blocked)
  #expect(throws: PCMInputError.self) {
    try guardrail.attempt { try guardrail.attempt { throw PCMInputError.format } }
  }
  #expect(!RecordingStartGuard(dataDirectory: dir).blocked)
  try guardrail.attempt { #expect(RecordingStartGuard(dataDirectory: dir).blocked) }
  #expect(!RecordingStartGuard(dataDirectory: dir).blocked)
}
