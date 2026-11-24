import Darwin
import Foundation

/// Preparing leaves the current local route in place. Publishing another active route advances generation.
public struct HubBinding: Codable, Equatable, Sendable {
  public enum Target: String, Codable, Hashable, Sendable { case local, remote }
  public enum Phase: String, Codable, Sendable { case local, preparing, committed, switching_back }

  public struct Remote: Codable, Hashable, Sendable {
    public let hub_id: String
    public let hub_pk: String
    public let dir: String

    public init(hubID: String, hubPublicKey: String) throws {
      guard let key = DeviceProtocol.base64URLDecode(hubPublicKey, expectedLength: 32),
            try DeviceProtocol.hubID(forPublicKey: key) == hubID else { throw Failure.invalidBinding }
      hub_id = hubID
      hub_pk = hubPublicKey
      dir = "remote-\(hubID)"
    }

    private enum CodingKeys: String, CodingKey { case hub_id, hub_pk, dir }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(hubID: values.decode(String.self, forKey: .hub_id),
                    hubPublicKey: values.decode(String.self, forKey: .hub_pk))
      guard try values.decode(String.self, forKey: .dir) == dir else { throw Failure.invalidBinding }
    }

    fileprivate func validate() throws {
      guard self == (try Self(hubID: hub_id, hubPublicKey: hub_pk)) else { throw Failure.invalidBinding }
    }
  }

  public struct Route: Codable, Hashable, Sendable {
    public let generation: Int
    public let remote: Remote?
    public static let local = Route(generation: 0, remote: nil)
  }

  public enum Failure: Error, Equatable { case invalidBinding, changed }

  public static let fileName = "hub-binding.json"
  public static let legacyLocal = HubBinding(generation: 0, target: .local, phase: .local)
  public let version: Int
  public let generation: Int
  public let target: Target
  public let phase: Phase
  public let remote: Remote?
  public let updated_at: String

  public var route: Route {
    Route(generation: generation, remote: target == .remote && (phase == .committed || phase == .switching_back) ? remote : nil)
  }

  public init(generation: Int, target: Target, phase: Phase, remote: Remote? = nil, updatedAt: Date = Date()) {
    version = 1
    self.generation = generation
    self.target = target
    self.phase = phase
    self.remote = remote
    updated_at = DeviceProtocol.formatRFC3339(updatedAt)
  }

  private enum CodingKeys: String, CodingKey { case version, generation, target, phase, remote, updated_at }

  // Stable sentinel for installations with no binding file.
  private init(generation: Int, target: Target, phase: Phase) {
    self.init(generation: generation, target: target, phase: phase, updatedAt: Date(timeIntervalSince1970: 0))
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    generation = try values.decode(Int.self, forKey: .generation)
    target = try values.decode(Target.self, forKey: .target)
    phase = try values.decode(Phase.self, forKey: .phase)
    remote = try values.decodeIfPresent(Remote.self, forKey: .remote)
    // The hub treats this timestamp as informational.
    updated_at = (try? values.decode(String.self, forKey: .updated_at)) ?? Self.legacyLocal.updated_at
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(version, forKey: .version)
    try values.encode(generation, forKey: .generation)
    try values.encode(target, forKey: .target)
    try values.encode(phase, forKey: .phase)
    try values.encode(remote, forKey: .remote)
    try values.encode(updated_at, forKey: .updated_at)
  }

  private func validate() throws {
    guard version == 1, (0...9_007_199_254_740_991).contains(generation) else {
      throw Failure.invalidBinding
    }
    switch (target, phase, remote) {
    case (.local, .local, nil): break
    case (.remote, .preparing, .some(let identity)): try identity.validate()
    case (.remote, .committed, .some(let identity)), (.remote, .switching_back, .some(let identity)):
      guard generation > 0 else { throw Failure.invalidBinding }
      try identity.validate()
    default: throw Failure.invalidBinding
    }
  }

  public static func read(from directory: URL) throws -> Self {
    do {
      guard let data = try BindingFile.read(fileName, in: directory, limit: 64 * 1024, allowOwnerOnly: true) else { return .legacyLocal }
      return try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw Failure.invalidBinding
    }
  }

  private static let writeLock = NSLock()

  /// The Mac host owns writes. Compare the previously read state before publishing a transition.
  public func write(to directory: URL, replacing previous: Self) throws {
    try Self.writeLock.withLock {
      try validate()
      guard try Self.read(from: directory) == previous else { throw Failure.changed }
      let rePaired = remote != nil && remote == previous.remote && phase == .committed &&
        previous.phase == .committed && generation > previous.generation
      let isSwitch = rePaired || route.remote != previous.route.remote
      let (expectedGeneration, overflow) = previous.generation.addingReportingOverflow(isSwitch ? 1 : 0)
      guard !overflow, generation == expectedGeneration else { throw Failure.invalidBinding }
      try BindingFile.write(JSONEncoder().encode(self), named: Self.fileName, in: directory)
    }
  }
}

/// Small public-metadata files, opened relative to a pinned directory descriptor.
enum BindingFile {
  static func withDirectory<T>(_ directory: URL, missing: T, _ operation: (Int32) throws -> T) throws -> T {
    let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if dir < 0 && errno == ENOENT { return missing }
    guard dir >= 0 else { throw LocalDeviceLink.Failure.unsafeFile }
    defer { close(dir) }
    return try operation(dir)
  }

  static func read(_ name: String, in directory: URL, limit: Int = 16_384, allowOwnerOnly: Bool = false) throws -> Data? {
    try withDirectory(directory, missing: nil) { dir in
      let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      if fd < 0 && errno == ENOENT { return nil }
      guard fd >= 0 else { throw LocalDeviceLink.Failure.unsafeFile }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, safe(info, allowOwnerOnly: allowOwnerOnly), info.st_size <= limit else {
        throw LocalDeviceLink.Failure.unsafeFile
      }
      let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
      guard bytes.count <= limit else { throw LocalDeviceLink.Failure.unsafeFile }
      return bytes
    }
  }

  static func write(_ data: Data, named name: String, in directory: URL, limit: Int = 16_384) throws {
    guard data.count <= limit else { throw LocalDeviceLink.Failure.fileIO }
    let written = try withDirectory(directory, missing: false) { dir in
      let tmp = ".binding-\(UUID().uuidString)"
      let fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw LocalDeviceLink.Failure.fileIO }
      defer { close(fd); _ = unlinkat(dir, tmp, 0) }
      guard fchmod(fd, 0o600) == 0 else { throw LocalDeviceLink.Failure.fileIO }
      try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
      guard fsync(fd) == 0 else { throw LocalDeviceLink.Failure.fileIO }
      var info = stat()
      if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        guard safe(info, allowOwnerOnly: name == HubBinding.fileName) else { throw LocalDeviceLink.Failure.unsafeFile }
      } else if errno != ENOENT {
        throw LocalDeviceLink.Failure.fileIO
      }
      guard renameat(dir, tmp, dir, name) == 0 else { throw LocalDeviceLink.Failure.fileIO }
      // Publication has already happened. A sync error cannot undo the rename.
      _ = fsync(dir)
      return true
    }
    guard written else { throw LocalDeviceLink.Failure.fileIO }
  }

  static func remove(_ name: String, in directory: URL) throws {
    _ = try withDirectory(directory, missing: false) { dir in
      guard unlinkat(dir, name, 0) == 0 || errno == ENOENT else { throw LocalDeviceLink.Failure.fileIO }
      _ = fsync(dir)
      return true
    }
  }

  private static func safe(_ info: stat, allowOwnerOnly: Bool) -> Bool {
    info.st_mode & S_IFMT == S_IFREG
      && (allowOwnerOnly ? info.st_mode & 0o077 == 0 : info.st_mode & 0o777 == 0o600)
  }
}
