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

@Test func pcmBatcherCoalescesChunksPreservesHostAndHandlesDiscontinuity() {
  var batcher = PCMBatcher(targetDuration: 0.1, maxDiscontinuity: 0.05, maxTrailingSilence: 0.2)
  let rate = 1000.0, tps = 1_000_000.0
  var emitted: [(count: Int, rate: Double, host: UInt64)] = []
  let collect: ([Float], Double, UInt64) -> Void = { emitted.append(($0.count, $1, $2)) }

  // 4 个 30ms 小块拼满 100ms 才派发一次，保留首块 hostTime。
  for i in 0..<3 {
    batcher.append([Float](repeating: 0.1, count: 30), rate: rate, host: UInt64(i * 30_000), ticksPerSecond: tps, emit: collect)
  }
  #expect(emitted.isEmpty)
  batcher.append([Float](repeating: 0.1, count: 30), rate: rate, host: 90_000, ticksPerSecond: tps, emit: collect)
  #expect(emitted.count == 1)
  #expect(emitted[0].count == 120 && emitted[0].host == 0)

  // 时间跳变超过阈值时先刷出旧缓冲，再从新 hostTime 起算。
  batcher.append([Float](repeating: 0.2, count: 30), rate: rate, host: 120_000, ticksPerSecond: tps, emit: collect)
  batcher.append([Float](repeating: 0.2, count: 30), rate: rate, host: 500_000, ticksPerSecond: tps, emit: collect)
  #expect(emitted.count == 2)
  #expect(emitted[1].count == 30 && emitted[1].host == 120_000)
  batcher.flush(emit: collect)
  #expect(emitted.count == 3)
  #expect(emitted[2].count == 30 && emitted[2].host == 500_000)
}

@Test func pcmBatcherSuppressesIdleZeroFramesAfterTrailingSilence() {
  var batcher = PCMBatcher(targetDuration: 0.1, maxDiscontinuity: 0.05, maxTrailingSilence: 0.2)
  let rate = 1000.0, tps = 1_000_000.0
  var emitted: [(samples: [Float], host: UInt64)] = []
  let collect: ([Float], Double, UInt64) -> Void = { emitted.append(($0, $2)) }

  // 从未有非零声音时，全零静音直接跳过。
  for i in 0..<10 {
    batcher.appendZeroFrames(count: 50, rate: rate, host: UInt64(i * 50_000), ticksPerSecond: tps, emit: collect)
  }
  #expect(emitted.isEmpty)

  // 出现声音后，最多补送 200ms 尾部静音让 VAD 收尾，再之后的连续静音不再派发。
  batcher.append([Float](repeating: 0.25, count: 50), rate: rate, host: 1_000_000, ticksPerSecond: tps, emit: collect)
  for i in 1...10 {
    batcher.appendZeroFrames(count: 50, rate: rate, host: UInt64(1_000_000 + i * 50_000), ticksPerSecond: tps, emit: collect)
  }
  let totalSamples = emitted.reduce(0) { $0 + $1.samples.count }
  #expect(totalSamples == 250) // 50 non-zero + 200 trailing zero
  let beforeMore = emitted.count
  batcher.appendZeroFrames(count: 500, rate: rate, host: 2_000_000, ticksPerSecond: tps, emit: collect)
  #expect(emitted.count == beforeMore)
}
