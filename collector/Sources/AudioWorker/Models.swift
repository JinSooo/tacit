import Foundation
import CSherpa
import CollectorCore

enum WorkerError: String, Error { case arguments, models, embedding, transcription, http, response, cache, recordTooLarge, pendingDelivery, deliveryPaused }
final class Strings {
  var pointers: [UnsafeMutablePointer<CChar>] = []
  func c(_ value: String) -> UnsafePointer<CChar> { let p = strdup(value)!; pointers.append(p); return UnsafePointer(p) }
  deinit { pointers.forEach { free($0) } }
}
struct Recognition {
  let text: String
  let confidence: Double?
  var language: String? = nil
}
protocol Inference {
  func embedding(_ samples: [Float]) throws -> [Float]
  func transcribe(_ samples: [Float]) throws -> Recognition
}
final class Models: Inference {
  let strings = Strings()
  let directory: URL
  private var recognizer: OpaquePointer?
  private var extractor: OpaquePointer?
  init(directory: URL) throws { self.directory = directory }
  private func speakerModel() throws -> OpaquePointer {
    if let extractor { return extractor }
    let file = directory.appendingPathComponent("3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")
    guard FileManager.default.isReadableFile(atPath: file.path) else { throw WorkerError.models }
    var ec = SherpaOnnxSpeakerEmbeddingExtractorConfig()
    ec.model = strings.c(file.path); ec.num_threads = 4; ec.provider = strings.c("cpu")
    guard let value = SherpaOnnxCreateSpeakerEmbeddingExtractor(&ec) else { throw WorkerError.models }
    guard SherpaOnnxSpeakerEmbeddingExtractorDim(value) == 512 else {
      SherpaOnnxDestroySpeakerEmbeddingExtractor(value); throw WorkerError.models
    }
    extractor = value; return value
  }
  private func transcriptionModel() throws -> OpaquePointer {
    if let recognizer { return recognizer }
    let model = directory.appendingPathComponent("sense-voice/model.int8.onnx")
    let tokens = directory.appendingPathComponent("sense-voice/tokens.txt")
    guard [model, tokens].allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else { throw WorkerError.models }
    var rc = SherpaOnnxOfflineRecognizerConfig()
    rc.feat_config.sample_rate = 16000; rc.feat_config.feature_dim = 80
    rc.model_config.sense_voice.model = strings.c(model.path)
    rc.model_config.sense_voice.language = strings.c("auto"); rc.model_config.sense_voice.use_itn = 1
    rc.model_config.tokens = strings.c(tokens.path)
    rc.model_config.num_threads = 4; rc.model_config.provider = strings.c("cpu"); rc.decoding_method = strings.c("greedy_search")
    guard let value = SherpaOnnxCreateOfflineRecognizer(&rc) else { throw WorkerError.models }
    recognizer = value; return value
  }
  deinit {
    if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
    if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
  }
  func embedding(_ samples: [Float]) throws -> [Float] {
    let extractor = try speakerModel()
    guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { throw WorkerError.embedding }
    defer { SherpaOnnxDestroyOnlineStream(stream) }
    samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count)) }
    SherpaOnnxOnlineStreamInputFinished(stream)
    guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
          let vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { throw WorkerError.embedding }
    defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
    let result = WorkerLogic.unit(Array(UnsafeBufferPointer(start: vector, count: 512)))
    guard result.count == 512 else { throw WorkerError.embedding }; return result
  }
  func transcribe(_ samples: [Float]) throws -> Recognition {
    let recognizer = try transcriptionModel()
    guard !samples.isEmpty, samples.count <= Int(Int32.max), let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw WorkerError.transcription }
    defer { SherpaOnnxDestroyOfflineStream(stream) }
    samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
    SherpaOnnxDecodeOfflineStream(recognizer, stream)
    guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw WorkerError.transcription }
    defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
    let value = result.pointee
    var confidence: Double?
    if value.count > 0, let probabilities = value.ys_log_probs {
      let scores = Array(UnsafeBufferPointer(start: probabilities, count: Int(value.count)))
      if scores.allSatisfy({ $0.isFinite && $0 <= 0 }) {
        confidence = scores.reduce(0.0) { $0 + exp(Double($1)) } / Double(scores.count)
      }
    }
    let detected = value.lang.map { String(cString: $0).trimmingCharacters(in: CharacterSet(charactersIn: "<|>")).lowercased() }
    let language = detected.flatMap { ["zh", "yue", "en", "ja", "ko"].contains($0) ? $0 : nil }
    return Recognition(text: String(cString: value.text).split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces),
      confidence: confidence, language: language)
  }
}
