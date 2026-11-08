import Foundation
import AVFoundation
import CoreAudio
import Darwin
import AudioCommon

func check(_ status: OSStatus, _ step: String) throws {
    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> (24 - $0 * 8)) }
    let fourCC = String(bytes: bytes.map { (32...126).contains($0) ? $0 : 46 }, encoding: .ascii)!
    print("\(step)：OSStatus=\(status) ('\(fourCC)')")
    guard status == noErr else { throw ExperimentError("卡在「\(step)」，OSStatus=\(status)；检查录音权限、PID 和输出设备") }
}
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
// 探针将回调数据暂存在内存，结束后统一重采样写盘；不是生产实时录音实现。
final class CaptureBuffer: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    var firstHost: UInt64?
    var rate = 0.0
    var failure: String?
    func append(_ data: [Float], rate: Double, host: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if self.rate != 0 && self.rate != rate { failure = "录音期间采样率变化"; return }
        self.rate = rate
        if firstHost == nil { firstHost = host }
        samples.append(contentsOf: data)
    }
    func fail(_ text: String) { lock.lock(); failure = text; lock.unlock() }
    func save(_ path: String) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw ExperimentError(failure) }
        guard !samples.isEmpty, rate > 0, let firstHost else { throw ExperimentError("未收到音频回调，不能写出有效录音") }
        try writeWave(resample(samples, rate: rate), path: path)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        print("\(path)：\(samples.count) 输入样本，\(Double(samples.count)/rate) 秒，RMS=\(rms)，首帧 hostTime=\(firstHost)")
        return firstHost
    }
}
final class Microphone {
    let engine = AVAudioEngine()
    let buffer = CaptureBuffer()
    var installed = false
    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        print("麦克风实际格式：\(format)")
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ExperimentError("麦克风格式不可用") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [buffer] pcm, time in
            guard time.isHostTimeValid, let channels = pcm.floatChannelData else { buffer.fail("麦克风无有效 hostTime 或 Float32 数据"); return }
            let count = Int(pcm.frameLength), c = Int(pcm.format.channelCount)
            var mono = [Float](repeating: 0, count: count)
            for i in 0..<count { for j in 0..<c { mono[i] += channels[j][i * pcm.stride] / Float(c) } }
            buffer.append(mono, rate: pcm.format.sampleRate, host: time.hostTime)
        }
        installed = true
        try engine.start()
        print("AVAudioEngine.start：成功（此 API 抛 Error，无 OSStatus 返回值）")
    }
    func stop() { engine.stop(); if installed { engine.inputNode.removeTap(onBus: 0); installed = false } }
    deinit { stop() }
}
@available(macOS 14.2, *)
final class SystemTap {
    var tap: AudioObjectID = 0, device: AudioObjectID = 0
    var io: AudioDeviceIOProcID?
    var started = false
    let buffer = CaptureBuffer()
    let queue = DispatchQueue(label: "audio-probe.tap")
    func start(pid: Int32?) throws {
        let description: CATapDescription
        if var pid {
            var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var object: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                UInt32(MemoryLayout<Int32>.size), &pid, &size, &object), "PID 转 process AudioObjectID")
            guard object != 0 else { throw ExperimentError("PID 没有对应的 Core Audio process object；目标进程需正在输出声音") }
            description = CATapDescription(stereoMixdownOfProcesses: [object])
        } else { description = CATapDescription(stereoGlobalTapButExcludeProcesses: []) }
        description.name = "RA 音频实验"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "创建 process tap")
        var a = address(kAudioTapPropertyFormat), asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &asbd), "读取 tap 实际格式")
        print("Tap 实际格式：\(asbd)")
        // 只接受明确可解码的 Float32 PCM，避免误读或静默产生错误录音。
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw ExperimentError("tap 返回非 Float32 little-endian PCM；本探针不支持该格式")
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RA Audio Probe", kAudioAggregateDeviceUIDKey: UUID().uuidString,
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
func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] { print("用法：probe mic|tap|both --seconds N [--pid P（仅 tap）]；在实验目录运行"); return }
    guard let mode = args.first, ["mic", "tap", "both"].contains(mode) else { throw ExperimentError("用法：probe mic|tap|both --seconds N [--pid P]") }
    var seconds: Double?, pid: Int32?
    var i = 1
    while i < args.count {
        guard i + 1 < args.count else { throw ExperimentError("参数缺值") }
        switch args[i] {
        case "--seconds": seconds = Double(args[i+1])
        case "--pid": pid = Int32(args[i+1]); if pid == nil || pid! <= 0 { throw ExperimentError("PID 必须是正整数") }
        default: throw ExperimentError("未知参数：\(args[i])")
        }
        i += 2
    }
    guard let seconds, seconds.isFinite, seconds > 0, seconds <= 3600 else { throw ExperimentError("seconds 必须在 (0,3600] 内；探针在内存缓存音频，请优先短测") }
    guard pid == nil || mode == "tap" else { throw ExperimentError("--pid 仅用于 tap") }
    guard #available(macOS 14.2, *) else { throw ExperimentError("tap/both 需要 macOS 14.2；本探针运行入口统一要求 14.2") }
    try FileManager.default.createDirectory(atPath: "out", withIntermediateDirectories: true)
    let mic = Microphone(), tap = SystemTap()
    defer { mic.stop(); tap.stop() }
    if mode != "tap" { try mic.start() }
    if mode != "mic" { try tap.start(pid: pid) }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1))) }
    mic.stop(); tap.stop()
    var micHost: UInt64?, tapHost: UInt64?
    if mode != "tap" { micHost = try mic.buffer.save("out/mic.wav") }
    if mode != "mic" { tapHost = try tap.buffer.save("out/tap.wav") }
    if let micHost, let tapHost {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        let ms = (Double(tapHost) - Double(micHost)) * Double(info.numer) / Double(info.denom) / 1e6
        print("首帧时间戳差（tap - mic）=\(ms) ms；包含顺序启动偏差，不代表漂移或声学延迟")
    }
}
let baseline = usage(), start = now()
var exitStatus: Int32 = 0
do { try run() } catch { fputs("录音探针失败：\(error)\n", stderr); exitStatus = 1 }
let final = usage()
print("墙钟时间=\(now()-start) 秒，CPU 时间=\(final.cpu-baseline.cpu) 秒，峰值 RSS=\(final.peakRSS) bytes")

exit(exitStatus)
