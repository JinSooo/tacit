import CryptoKit
import Foundation

/// Space and box identifiers are public routing metadata. Credentials stay in the Keychain.
public struct RemoteRelayMailbox: Codable, Hashable, Sendable {
  public let url: String
  public let space: String
  public let up: String
  public let down: String

  init(_ config: DeviceRelayConfig) {
    (url, space, up, down) = (config.url, config.space, config.up, config.down)
  }

  var credentialSuffix: String {
    let address = Data("\(url)\n\(space)\n\(up)\n\(down)".utf8)
    return SHA256.hash(data: address).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}

public struct RemoteRelayJournal: Codable, Sendable {
  public struct Delivery: Codable, Sendable {
    public let nonce: String
    public let operation: String
    public let recordIDs: [String]
    public let mailbox: RemoteRelayMailbox
    public let createdAt: Date
    public let capture: Bool
    let fingerprint: Data
    var body: [String: DeviceJSON]?
    var wire: Data?
    public internal(set) var putConfirmed = false
    public internal(set) var reply: Data?
    var attemptedPut = false
    var retry = false
    var queueConfirmed = false
    var abandoned = false
    var removedFromMailbox = false
    var countedMissingIDs: Set<String>?
  }

  struct Superseded: Codable, Sendable {
    let nonce: String
    let mailbox: RemoteRelayMailbox
    let createdAt: Date
  }

  struct RetryDelay: Codable, Sendable {
    let until: Date
    let seconds: TimeInterval
    var status: Int?
  }

  struct Retirement: Codable, Sendable {
    let mailbox: RemoteRelayMailbox
    let until: Date
  }

  public let route: HubBinding.Route
  public let deviceID: String
  public internal(set) var deliveries: [Delivery] = []
  public internal(set) var unknownOutcomes = 0
  var configured = false
  var lastSuccessfulOrigin: URL?
  var active: RemoteRelayMailbox?
  var retired: [Retirement] = []
  var disabled: [RemoteRelayMailbox] = []
  var retryDelays: [String: RetryDelay]?
  var captureBatchLimit: Int?
  var relayOversizedCaptureIDs: Set<String>?
  // Persist superseded IDs until their original mailbox expires, so a late reply
  // can be authenticated and discarded without affecting a newer attempt.
  var superseded: [Superseded] = []

  public static let reservedBytes = 16 * 1024 * 1024
  static let snapshotLimit = reservedBytes / 2

  static func name(for route: HubBinding.Route) -> String { "relay-delivery-\(route.generation).enc" }

  static func key(for raw: Data, route: HubBinding.Route, deviceID: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw),
      info: Data("tacit-remote-relay-journal-v1:\(deviceID):\(route.generation)".utf8), outputByteCount: 32)
  }

  var outcomesOnRetirement: Int {
    let unmatched = deliveries.filter {
      $0.operation == "ingest" && ($0.attemptedPut || $0.putConfirmed) && $0.reply == nil && !$0.retry && !$0.queueConfirmed
    }
    let ids = Set(unmatched.flatMap { Set($0.recordIDs).subtracting($0.countedMissingIDs ?? []) })
    return unknownOutcomes + ids.count
  }

  func account(for mailbox: RemoteRelayMailbox) -> String {
    RemoteDeviceLink.Relay.account(deviceID: deviceID) + "-" + mailbox.credentialSuffix
  }

  var mailboxAccounts: [String] {
    let mailboxes = deliveries.map(\.mailbox) + retired.map(\.mailbox) + disabled + superseded.map(\.mailbox)
    return Set(mailboxes + [active].compactMap { $0 }).map(account(for:)).sorted()
  }

  func save(key: SymmetricKey, in directory: URL, name: String, reserve: Int = 0) throws {
    let data = try JSONEncoder().encode(self)
    guard data.count + 28 <= Self.snapshotLimit - reserve else { throw RemoteDeviceSession.Failure.journalFull }
    guard let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(name.utf8)).combined else {
      throw RemoteDeviceSession.Failure.invalidJournal
    }
    try BindingFile.write(sealed, named: name, in: directory, limit: Self.snapshotLimit)
  }

  static func load(key: SymmetricKey, in directory: URL, name: String,
                   route: HubBinding.Route, deviceID: String) throws -> Self {
    guard let wire = try BindingFile.read(name, in: directory, limit: snapshotLimit) else {
      return Self(route: route, deviceID: deviceID)
    }
    let data = try AES.GCM.open(AES.GCM.SealedBox(combined: wire), using: key, authenticating: Data(name.utf8))
    let journal = try JSONDecoder().decode(Self.self, from: data)
    guard journal.route == route, journal.deviceID == deviceID else { throw RemoteDeviceSession.Failure.invalidJournal }
    return journal
  }
}
