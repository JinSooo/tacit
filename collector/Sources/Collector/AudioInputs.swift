import Foundation
import AVFoundation
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
final class Microphone {
    let engine = AVAudioEngine()
    let buffer: CaptureBuffer
    let device: AudioDeviceID?
    private(set) var actualDevice: AudioDeviceID?
    init(buffer: CaptureBuffer, device: AudioDeviceID?) { self.buffer = buffer; self.device = device }
    var installed = false
    func start() throws {
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw AudioCaptureError("麦克风 AudioUnit 不可用") }
        if var device {
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "选择麦克风")
        }
        var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size), "读取实际麦克风")
        guard actual != 0, device == nil || actual == device else { throw AudioCaptureError("麦克风未切换到指定设备") }
        actualDevice = actual
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError("麦克风格式不可用") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [buffer] pcm, time in
            guard time.isHostTimeValid, let channels = pcm.floatChannelData else { buffer.fail("麦克风无有效 hostTime 或 Float32 数据"); return }
            let count = Int(pcm.frameLength), c = Int(pcm.format.channelCount)
            var mono = [Float](repeating: 0, count: count)
            for i in 0..<count { for j in 0..<c { mono[i] += channels[j][i * pcm.stride] / Float(c) } }
            buffer.append(mono, rate: pcm.format.sampleRate, host: time.hostTime)
        }
        installed = true
        try engine.start()
    }
    func stop() { engine.stop(); if installed { engine.inputNode.removeTap(onBus: 0); installed = false } }
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
    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Record Anything"
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
            kAudioAggregateDeviceNameKey: "Record Anything Audio", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "创建 aggregate device")
        let sampleRate = asbd.mSampleRate, expectedChannels = Int(asbd.mChannelsPerFrame)
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { [buffer] _, input, inputTime, _, _ in
            guard inputTime.pointee.mFlags.contains(.hostTimeValid) else { buffer.fail("系统声音缺少有效 hostTime"); return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard !buffers.isEmpty else { return }
            var frameCount: Int?
            var totalChannels = 0
            for b in buffers {
                guard b.mNumberChannels > 0, b.mData != nil else { continue }
                let n = Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels))
                if let count = frameCount, count != n { buffer.fail("tap 各通道帧数不一致"); return }
                frameCount = n; totalChannels += Int(b.mNumberChannels)
            }
            guard let count = frameCount, count > 0 else { return }
            guard totalChannels == expectedChannels else { buffer.fail("tap 回调通道数与格式不一致"); return }
            var mono = [Float](repeating: 0, count: count)
            for b in buffers {
                guard let raw = b.mData, b.mNumberChannels > 0 else { continue }
                let data = raw.assumingMemoryBound(to: Float.self), c = Int(b.mNumberChannels)
                for i in 0..<count { for j in 0..<c { mono[i] += data[i*c+j] / Float(totalChannels) } }
            }
            buffer.append(mono, rate: sampleRate, host: inputTime.pointee.mHostTime)
        }, "创建 IOProc")
        try check(AudioDeviceStart(device, io), "启动 aggregate device")
        started = true
    }
    func stop() {
        if started { try? check(AudioDeviceStop(device, io), "停止 aggregate device"); started = false }
        if let io { try? check(AudioDeviceDestroyIOProcID(device, io), "销毁 IOProc"); self.io = nil }
        // 等串行回调队列排空后再读取数据和销毁 tap。
        queue.sync {}
        if device != 0 { try? check(AudioHardwareDestroyAggregateDevice(device), "销毁 aggregate device"); device = 0 }
        if tap != 0 { try? check(AudioHardwareDestroyProcessTap(tap), "销毁 process tap"); tap = 0 }
    }
    deinit { stop() }
}
