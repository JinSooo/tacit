import Foundation

/// The import checkpoint contains cursors and receipt metadata, never exported record content.
public enum HistoryImportJournalFile {
  private static let limit = 128 * 1024 * 1024

  public static func read(in directory: URL, for remote: HubBinding.Remote) throws -> Data? {
    try BindingFile.read("history-import-\(remote.hub_id).json", in: directory, limit: limit)
  }

  public static func pause(in directory: URL, for route: HubBinding.Route) throws -> Bool? {
    guard let remote = route.remote,
          let data = try BindingFile.read("history-pause-\(remote.hub_id).json", in: directory, limit: 128) else { return nil }
    let state = try JSONDecoder().decode(Pause.self, from: data)
    return state.generation == route.generation ? state.paused : nil
  }

  public static func setPause(_ paused: Bool, in directory: URL, for route: HubBinding.Route) throws {
    guard let remote = route.remote else { throw HubBinding.Failure.changed }
    let state = Pause(generation: route.generation, paused: paused)
    try BindingFile.write(JSONEncoder().encode(state), named: "history-pause-\(remote.hub_id).json", in: directory, limit: 128)
  }

  private struct Pause: Codable {
    let generation: Int
    let paused: Bool
  }

  public static func write(_ data: Data, in directory: URL, for remote: HubBinding.Remote) throws {
    try BindingFile.write(data, named: "history-import-\(remote.hub_id).json", in: directory, limit: limit)
  }
}
