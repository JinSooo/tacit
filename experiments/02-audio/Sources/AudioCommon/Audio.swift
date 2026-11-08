import Foundation
import AVFoundation
import Darwin

public struct ExperimentError: Error, CustomStringConvertible {
    public let description: String
    public init(_ text: String) { description = text }
}
public func now() -> Double { ProcessInfo.processInfo.systemUptime }
public func usage() -> (cpu: Double, peakRSS: Int64) {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return (Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec)
        + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6, Int64(u.ru_maxrss))
}
public func resample(_ samples: [Float], rate: Double) -> [Float] {
    guard !samples.isEmpty else { return [] }
    if rate == 16000 { return samples }
    let count = Int((Double(samples.count) * 16000 / rate).rounded())
    return (0..<count).map { i in
        let p = Double(i) * rate / 16000
        let a = min(Int(p), samples.count - 1), b = min(a + 1, samples.count - 1)
        return samples[a] + (samples[b] - samples[a]) * Float(p - Double(a))
    }
}
public func readWave(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw ExperimentError("无法分配 WAV 缓冲")
    }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else { throw ExperimentError("WAV 无浮点数据") }
    let n = Int(buffer.frameLength), c = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    for i in 0..<n { for j in 0..<c { mono[i] += channels[j][i * buffer.stride] / Float(c) } }
    return resample(mono, rate: format.sampleRate)
}
public func writeWave(_ samples: [Float], path: String) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
        throw ExperimentError("无法分配输出缓冲")
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        if let base = src.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
    }
    try file.write(from: buffer)
}
public func writeJSON(_ object: Any, path: String) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
}
