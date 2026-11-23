import Foundation
import CoreAudio
import AudioToolbox
import Darwin
import CollectorCore

func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw AudioCaptureError("卡在「\(step)」，OSStatus=\(status)；检查录音权限、PID 和输出设备") }
}
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
/// 回调只复制小块 PCM，推理和编码在有界的串行队列执行。
final class CaptureBuffer: @unchecked Sendable {
    let receive: ([Float], Double, UInt64) -> Void
    let failure: (String) -> Void
    init(receive: @escaping ([Float], Double, UInt64) -> Void, failure: @escaping (String) -> Void) {
        self.receive = receive; self.failure = failure
    }
    func append(_ data: [Float], rate: Double, host: UInt64) { receive(data, rate, host) }
    func fail(_ text: String) { failure(text) }
}
struct AudioCaptureError: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
private let hostTicksPerSecond: Double = {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0 else { return 24_000_000 }
    return Double(timebase.denom) / Double(timebase.numer) * 1_000_000_000
}()

final class Microphone {
    let buffer: CaptureBuffer
    let device: AudioDeviceID
    private(set) var actualDevice: AudioDeviceID?
    private var io: AudioDeviceIOProcID?
    private var started = false
    private let queue = DispatchQueue(label: "record-anything.audio.microphone")
    private var batcher = PCMBatcher()
    init(buffer: CaptureBuffer, device: AudioDeviceID) { self.buffer = buffer; self.device = device }

    func start() throws {
        guard device != 0 else { throw AudioCaptureError("没有可用的麦克风设备") }
        // 属性查询只针对选中的 ID；不创建 AVAudioEngine，也不打开默认输入。
        let formats = try MicrophoneDevices.inputFormats(device)
        guard let rate = formats.first?.rate, formats.allSatisfy({ $0.rate == rate }) else {
            throw AudioCaptureError("麦克风各输入流采样率不一致")
        }
        batcher = PCMBatcher()
        do {
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { [weak self, buffer] _, input, inputTime, _, _ in
                guard let self else { return }
                guard inputTime.pointee.mFlags.contains(.hostTimeValid) else { buffer.fail("麦克风缺少有效 hostTime"); return }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                do {
                    let buffers = try list.map { value -> PCMInputBuffer in
                        guard value.mData != nil || value.mDataByteSize == 0 else { throw PCMInputError.buffers }
                        return PCMInputBuffer(channels: Int(value.mNumberChannels),
                            bytes: UnsafeRawBufferPointer(start: value.mData, count: Int(value.mDataByteSize)))
                    }
                    let mono = try PCMInputFormat.downmix(formats: formats, buffers: buffers)
                    if !mono.isEmpty {
                        self.batcher.append(mono, rate: rate, host: inputTime.pointee.mHostTime, ticksPerSecond: hostTicksPerSecond) {
                            buffer.append($0, rate: $1, host: $2)
                        }
                    }
                } catch { buffer.fail("麦克风输入格式或缓冲不匹配：\(error)") }
            }, "创建麦克风 IOProc")
            try check(AudioDeviceStart(device, io), "启动指定麦克风")
            started = true; actualDevice = device
        } catch { stop(); throw error }
    }
    func stop() {
        if started { AudioDeviceStop(device, io); started = false }
        if let io { AudioDeviceDestroyIOProcID(device, io); self.io = nil }
        queue.sync {
            batcher.flush { buffer.append($0, rate: $1, host: $2) }
        }
        actualDevice = nil
    }
    deinit { stop() }
}
@available(macOS 14.2, *)
final class SystemTap {
    var tap: AudioObjectID = 0, device: AudioObjectID = 0
    var io: AudioDeviceIOProcID?
    var started = false
    let buffer: CaptureBuffer
    init(buffer: CaptureBuffer) { self.buffer = buffer }
    let queue = DispatchQueue(label: "record-anything.audio.tap")
    private var batcher = PCMBatcher()
    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Tacit"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "创建 process tap")
        var a = address(kAudioTapPropertyFormat), asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &asbd), "读取 tap 实际格式")
        // 只接受明确可解码的 Float32 PCM，避免误读或静默产生错误录音。
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw AudioCaptureError("tap 返回非 Float32 little-endian PCM；无法解码该格式")
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tacit Audio", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "创建 aggregate device")
        let sampleRate = asbd.mSampleRate, expectedChannels = Int(asbd.mChannelsPerFrame)
        batcher = PCMBatcher()
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { [weak self, buffer] _, input, inputTime, _, _ in
            guard let self else { return }
            guard inputTime.pointee.mFlags.contains(.hostTimeValid) else { buffer.fail("系统声音缺少有效 hostTime"); return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard !buffers.isEmpty else { return }
            var frameCount: Int?
            var totalChannels = 0
            var hasNonZero = false
            for b in buffers {
                guard b.mNumberChannels > 0, let raw = b.mData else { continue }
                let c = Int(b.mNumberChannels)
                let n = Int(b.mDataByteSize) / (4 * c)
                if let count = frameCount, count != n { buffer.fail("tap 各通道帧数不一致"); return }
                frameCount = n; totalChannels += c
                if !hasNonZero {
                    let data = raw.assumingMemoryBound(to: Float.self)
                    let total = n * c
                    for k in 0..<total where data[k] != 0 { hasNonZero = true; break }
                }
            }
            guard let count = frameCount, count > 0 else { return }
            guard totalChannels == expectedChannels else { buffer.fail("tap 回调通道数与格式不一致"); return }
            if !hasNonZero {
                self.batcher.appendZeroFrames(count: count, rate: sampleRate, host: inputTime.pointee.mHostTime, ticksPerSecond: hostTicksPerSecond) {
                    buffer.append($0, rate: $1, host: $2)
                }
                return
            }
            var mono = [Float](repeating: 0, count: count)
            let scale = 1.0 / Float(totalChannels)
            for b in buffers {
                guard let raw = b.mData, b.mNumberChannels > 0 else { continue }
                let data = raw.assumingMemoryBound(to: Float.self), c = Int(b.mNumberChannels)
                for i in 0..<count {
                    var sum: Float = 0
                    let base = i * c
                    for j in 0..<c { sum += data[base + j] }
                    mono[i] += sum * scale
                }
            }
            self.batcher.append(mono, rate: sampleRate, host: inputTime.pointee.mHostTime, ticksPerSecond: hostTicksPerSecond) {
                buffer.append($0, rate: $1, host: $2)
            }
        }, "创建 IOProc")
        try check(AudioDeviceStart(device, io), "启动 aggregate device")
        started = true
    }
    func stop() {
        if started { try? check(AudioDeviceStop(device, io), "停止 aggregate device"); started = false }
        if let io { try? check(AudioDeviceDestroyIOProcID(device, io), "销毁 IOProc"); self.io = nil }
        // 等串行回调队列排空后再读取数据和销毁 tap。
        queue.sync {
            batcher.flush { buffer.append($0, rate: $1, host: $2) }
        }
        if device != 0 { try? check(AudioHardwareDestroyAggregateDevice(device), "销毁 aggregate device"); device = 0 }
        if tap != 0 { try? check(AudioHardwareDestroyProcessTap(tap), "销毁 process tap"); tap = 0 }
    }
    deinit { stop() }
}
