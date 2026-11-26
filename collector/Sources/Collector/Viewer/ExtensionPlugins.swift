import Foundation
import SwiftUI
import enum CollectorCore.L10n

// 与 docs/plugins.md 的清单和本机管理 CLI 一致。
enum PluginValue: Codable, Equatable {
  case string(String), number(Double), boolean(Bool)
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let b = try? c.decode(Bool.self) { self = .boolean(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else { self = .string(try c.decode(String.self)) }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self { case .string(let s): try c.encode(s); case .number(let n): try c.encode(n); case .boolean(let b): try c.encode(b) }
  }
  var text: String { switch self { case .string(let s): return s; case .number(let n): return n.formatted(.number.grouping(.never)); case .boolean(let b): return b ? "true" : "false" } }
  var bool: Bool { if case .boolean(let b) = self { return b }; return false }
}
struct ExtensionManifest: Codable, Equatable {
  struct Field: Codable, Equatable, Identifiable {
    let key: String; let label: String; let type: String; let description: String?; let required: Bool?; let `default`: PluginValue?
    var id: String { key }
  }
  let schema: Int; let id: String; let name: String; let version: String; let description: String; let entry: String
  struct Access: Codable, Equatable { var readFiles: [String]?; var readDirectories: [String]? }
  let permissions: [String]; let config: [Field]; var access: Access?
}
struct ExtensionPlugin: Codable, Equatable, Identifiable {
  let manifest: ExtensionManifest; let origin: String; var revision: String?; var contentHash: String?; var values: [String: PluginValue]
  var id: String { manifest.id }
}
struct ExtensionPreview: Codable, Identifiable {
  let ticket: String; let manifest: ExtensionManifest; let origin: String; let updating: Bool; var revision: String?; var contentHash: String?; var previousRevision: String?; var values: [String: PluginValue]
  var id: String { ticket }
}
struct PluginRequest: Encodable {
  let action: String
  var source: String?; var id: String?; var ticket: String?; var values: [String: PluginValue]?; var deleteRecords: Bool?; var hub: String?
}
struct PluginResponse: Decodable {
  var plugins: [ExtensionPlugin]?; var preview: ExtensionPreview?; var plugin: ExtensionPlugin?; var deleted: Int?; var error: String?
}
struct PluginFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

@MainActor @Observable final class ExtensionSettings {
  var plugins: [ExtensionPlugin] = []
  var preview: ExtensionPreview?
  var busy = false
  var error: String?
  var message: String?
  func send(_ request: PluginRequest, store: ViewerStore) async -> PluginResponse? {
    guard !busy, let controls = store.controls else { return nil }
    busy = true; error = nil; message = nil
    defer { busy = false }
    do {
      let result = try await controls.pluginCommand(request)
      if let error = result.error { throw PluginFailure(message: error) }
      if let plugins = result.plugins { self.plugins = plugins }
      if let preview = result.preview { self.preview = preview }
      if let plugin = result.plugin {
        plugins.removeAll { $0.id == plugin.id }; plugins.append(plugin)
        if request.action == "install" { preview = nil; message = L10n.Settings.pluginInstalled }
        else { message = L10n.Settings.pluginSaved }
      }
      if request.action == "uninstall" { plugins.removeAll { $0.id == request.id }; message = request.deleteRecords == true ? L10n.Settings.pluginDeleted : L10n.Settings.pluginUninstalled }
      if request.action == "discard" { preview = nil }
      store.capture = controls.captureSnapshot()
      return result
    } catch { self.error = L10n.Settings.serviceMessage(error.localizedDescription, fallback: L10n.Settings.pluginOperationFailed); return nil }
  }
}
