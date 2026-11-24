import Foundation

/// Login and Finder startup must leave the frozen database alone until switch recovery finishes.
public enum LocalServiceStartupPolicy {
  public static let checkpointName = "hub-switch.json"

  public static func allowsBackground(in directory: URL) -> Bool {
    do {
      guard try HubBinding.read(from: directory).route.remote == nil else { return false }
      return try BindingFile.read(checkpointName, in: directory, limit: 128 * 1024) == nil
    } catch { return false }
  }

  public static func readCheckpoint(in directory: URL) throws -> Data? {
    try BindingFile.read(checkpointName, in: directory, limit: 128 * 1024)
  }

  public static func writeCheckpoint(_ data: Data, in directory: URL) throws {
    try BindingFile.write(data, named: checkpointName, in: directory, limit: 128 * 1024)
  }

  public static func removeCheckpoint(in directory: URL) throws {
    try BindingFile.remove(checkpointName, in: directory)
  }
}
