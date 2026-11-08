import Foundation
import Darwin
import AudioCommon
import CSherpa

// 配置中的 C 字符串由这个容器持有，覆盖所有推理句柄的生命周期。
final class Strings {
    var pointers: [UnsafeMutablePointer<CChar>] = []
    func c(_ value: String) -> UnsafePointer<CChar> {
        let p = strdup(value)!
        pointers.append(p)
        return UnsafePointer(p)
    }
    deinit { pointers.forEach { free($0) } }
}
func cosine(_ a: [Float], _ b: [Float]) -> Double {
    let dot = zip(a,b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    let aa = a.reduce(0.0) { $0 + Double($1) * Double($1) }
    let bb = b.reduce(0.0) { $0 + Double($1) * Double($1) }
    return dot / max(sqrt(aa * bb), 1e-20)
}
let modelDir = "vendor/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
let languages = ["zh", "en", "ja", "ko", "yue"]
func generate() throws {
    var result: [Float] = []
    let inputs = try languages.map { try readWave("\(modelDir)/test_wavs/\($0).wav") }
    // 循环五种语言，每段后留两秒静音；精确截到 600 秒。
    while result.count < 600 * 16000 {
        for input in inputs { result += input; result += [Float](repeating: 0, count: 32000) }
    }
    result = Array(result.prefix(600 * 16000))
    try writeWave(result, path: "out/long.wav")
    print("已生成 out/long.wav：\(Double(result.count)/16000) 秒")
}
func benchmark(model: String, threads: Int32) throws {
    let strings = Strings()
    let loadStart = now()
    var vc = SherpaOnnxVadModelConfig()
    vc.sample_rate = 16000; vc.num_threads = threads; vc.provider = strings.c("cpu")
    vc.silero_vad.model = strings.c("vendor/silero_vad.onnx")
    vc.silero_vad.threshold = 0.5; vc.silero_vad.min_silence_duration = 0.5
    vc.silero_vad.min_speech_duration = 0.25; vc.silero_vad.window_size = 512
    vc.silero_vad.max_speech_duration = 20
    guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vc, 60) else { throw ExperimentError("VAD 加载失败") }
    defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
    let vadLoad = now() - loadStart
    let asrStart = now()
    var rc = SherpaOnnxOfflineRecognizerConfig()
    rc.feat_config.sample_rate = 16000; rc.feat_config.feature_dim = 80
    rc.model_config.sense_voice.model = strings.c("\(modelDir)/\(model == "int8" ? "model.int8.onnx" : "model.onnx")")
    rc.model_config.sense_voice.language = strings.c("auto"); rc.model_config.sense_voice.use_itn = 1
    rc.model_config.tokens = strings.c("\(modelDir)/tokens.txt")
    rc.model_config.num_threads = threads; rc.model_config.provider = strings.c("cpu")
    rc.decoding_method = strings.c("greedy_search")
    guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&rc) else { throw ExperimentError("SenseVoice 加载失败") }
    defer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
    let asrLoad = now() - asrStart
    let speakerStart = now()
    var ec = SherpaOnnxSpeakerEmbeddingExtractorConfig()
    ec.model = strings.c("vendor/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")
    ec.num_threads = threads; ec.provider = strings.c("cpu")
    guard let extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&ec) else { throw ExperimentError("声纹模型加载失败") }
    defer { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
    let speakerLoad = now() - speakerStart
    let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
    guard dim > 0 else { throw ExperimentError("声纹维度无效") }
    func embedding(_ samples: [Float]) throws -> [Float] {
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { throw ExperimentError("声纹流创建失败") }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else {
            throw ExperimentError("语音段不足以计算声纹（\(samples.count) 样本）")
        }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
        return Array(UnsafeBufferPointer(start: vector, count: dim))
    }
    var rows: [[String: Any]] = [], vectors: [String: [[Float]]] = [:]
    for name in languages + ["long"] {
        let path = name == "long" ? "out/long.wav" : "\(modelDir)/test_wavs/\(name).wav"
        let start = now(), cpuStart = usage().cpu
        let samples = try readWave(path)
        let readSeconds = now() - start
        SherpaOnnxVoiceActivityDetectorReset(vad)
        var segments = 0, speechSamples = 0, asrSeconds = 0.0, speakerSeconds = 0.0
        var firstText: String? = nil
        func drain() throws {
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { throw ExperimentError("VAD 队列读取失败") }
                defer { SherpaOnnxDestroySpeechSegment(segment); SherpaOnnxVoiceActivityDetectorPop(vad) }
                let audio = Array(UnsafeBufferPointer(start: segment.pointee.samples, count: Int(segment.pointee.n)))
                segments += 1; speechSamples += audio.count
                let t = now()
                guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw ExperimentError("转写流创建失败") }
                defer { SherpaOnnxDestroyOfflineStream(stream) }
                audio.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
                SherpaOnnxDecodeOfflineStream(recognizer, stream)
                guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw ExperimentError("转写无结果") }
                if firstText == nil { firstText = String(String(cString: result.pointee.text).prefix(40)) }
                SherpaOnnxDestroyOfflineRecognizerResult(result)
                asrSeconds += now() - t
                let st = now()
                let v = try embedding(audio)
                if name != "long" { vectors[name, default: []].append(v) }
                speakerSeconds += now() - st
            }
        }
        // 逐窗喂入并及时取出，长输入不堆积 VAD 队列。
        try samples.withUnsafeBufferPointer { p in
            for offset in stride(from: 0, to: samples.count, by: 512) {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, p.baseAddress! + offset, Int32(min(512, samples.count - offset)))
                try drain()
            }
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad); try drain()
        let elapsed = now() - start, duration = Double(samples.count) / 16000
        guard segments > 0 else { throw ExperimentError("\(name) 未检测到语音") }
        let row: [String: Any] = ["file": name, "audio_seconds": duration, "processing_seconds": elapsed,
            "rtf": elapsed / duration, "cpu_seconds": usage().cpu - cpuStart, "read_seconds": readSeconds,
            "asr_seconds": asrSeconds, "speaker_seconds": speakerSeconds,
            "vad_and_overhead_seconds": elapsed - readSeconds - asrSeconds - speakerSeconds,
            "vad_segments": segments, "speech_seconds": Double(speechSamples)/16000]
        rows.append(row)
        print("\(model)/\(threads) \(name)：\(String(format: "%.3f", elapsed)) 秒，\(segments) 段，前40字：\(firstText ?? "")")
        fflush(stdout)
    }
    // 原始样例段不足两个时，额外取不重叠的前后窗口，仅用于相似度，不计入流水线 RTF。
    var same: [[String: Any]] = []
    for name in languages {
        let vs = vectors[name]!
        if vs.count >= 2 {
            same.append(["file": name, "method": "distinct_vad_segments", "cosine": cosine(vs[0], vs[1])])
        } else {
            let s = try readWave("\(modelDir)/test_wavs/\(name).wav")
            let n = min(48000, s.count / 2)
            same.append(["file": name, "method": "nonoverlapping_raw_windows", "window_seconds": Double(n)/16000,
                         "cosine": cosine(try embedding(Array(s.prefix(n))), try embedding(Array(s.suffix(n))))])
        }
    }
    var cross: [[String: Any]] = []
    for i in 0..<languages.count { for j in (i+1)..<languages.count {
        let a = languages[i], b = languages[j]
        cross.append(["a": a, "b": b, "cosine": cosine(vectors[a]![0], vectors[b]![0])])
    } }
    let totalAudio = rows.reduce(0.0) { $0 + ($1["audio_seconds"] as! Double) }
    let totalProcessing = rows.reduce(0.0) { $0 + ($1["processing_seconds"] as! Double) }
    try writeJSON(["model": model, "num_threads": threads, "provider": "cpu", "embedding_dim": dim,
        "load_seconds": ["vad": vadLoad, "asr": asrLoad, "speaker": speakerLoad, "total": vadLoad + asrLoad + speakerLoad],
        "peak_rss_bytes": usage().peakRSS, "files": rows, "overall_rtf": totalProcessing / totalAudio,
        "same_file_similarity": same, "cross_file_similarity": cross], path: "out/\(model)-t\(threads).json")
}
do {
    try FileManager.default.createDirectory(atPath: "out", withIntermediateDirectories: true)
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["generate"] { try generate() }
    else if args.count == 2, ["int8", "fp32"].contains(args[0]), let threads = Int32(args[1]), [1,2,4].contains(threads) {
        try benchmark(model: args[0], threads: threads)
    } else { throw ExperimentError("用法：bench generate | bench int8|fp32 1|2|4（在实验目录运行）") }
} catch { fputs("基准失败：\(error)\n", stderr); exit(1) }
