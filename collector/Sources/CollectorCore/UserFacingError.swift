import Foundation

public struct HubError: LocalizedError {
  /// 诊断信息只记固定类别。
  public enum Reason: String {
    case unreachable, timedOut = "timed_out", deviceLink = "device_link", badResponse = "bad_response", server, other
  }

  public let status: Int
  public let reason: Reason
  fileprivate let serviceMessage: String?
  fileprivate let localizedMessage: String?

  /// 来自后台的原文，显示前要经过可展示检查。
  public init(serviceMessage: String? = nil, status: Int, kind: Reason = .other) {
    self.init(serviceMessage: serviceMessage, localizedMessage: nil, status: status, kind: kind)
  }

  /// 来自客户端的本地化文案。
  public init(message: String, status: Int, kind: Reason = .other) {
    self.init(serviceMessage: nil, localizedMessage: message, status: status, kind: kind)
  }

  public init(networkCode: URLError.Code) {
    self.init(message: UserFacingError.networkMessage(networkCode), status: 0,
              kind: networkCode == .timedOut ? .timedOut : .unreachable)
  }

  private init(serviceMessage: String?, localizedMessage: String?, status: Int, kind: Reason) {
    self.status = status
    reason = kind == .other && (500...599).contains(status) ? .server : kind
    self.serviceMessage = serviceMessage
    self.localizedMessage = localizedMessage
  }

  public var message: String { UserFacingError.message(for: self, fallback: L10n.Settings.settingsRequestFailed) }
  public var errorDescription: String? { message }
  public var needsAction: Bool { [401, 403, 409, 429].contains(status) }
  public static var needsLocalHub: Self { .init(message: L10n.localServiceRequired, status: 0) }
  public static var invalidBinding: Self { .init(message: L10n.unreadableConnectionSettings, status: 0) }
  public static var remoteUnavailable: Self { .init(message: L10n.remoteServiceUnavailable, status: 0) }
  public static var needsDirectHub: Self { .init(message: L10n.directServiceRequired, status: 0) }
}

public enum UserFacingError {
  public static func message(for error: Error, fallback: String) -> String {
    if error is DecodingError { return L10n.unreadableResponse }
    if let hub = error as? HubError {
      if let message = hub.localizedMessage { return message }
      let standard = hubMessage(status: hub.status, reason: hub.reason, fallback: fallback)
      return hub.serviceMessage.map { L10n.Settings.serviceMessage($0, fallback: standard) } ?? standard
    }
    if let device = error as? DeviceClientError {
      switch device {
      case .transportError(_, let code): return networkMessage(code ?? .unknown)
      case .invalidInvitation: return L10n.Settings.inviteUnavailable
      case .plaintextError(let status, let detail), .operationError(_, let status, let detail):
        return message(for: HubError(serviceMessage: detail, status: status), fallback: fallback)
      case .deviceRemoved(let detail): return message(for: HubError(serviceMessage: detail, status: 401), fallback: fallback)
      case .hubBusy(let detail): return message(for: HubError(serviceMessage: detail, status: 503), fallback: fallback)
      case .envelopeTooLarge(let detail): return message(for: HubError(serviceMessage: detail, status: 413), fallback: fallback)
      default: return fallback
      }
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain { return networkMessage(URLError.Code(rawValue: nsError.code) ?? .unknown) }
    return fallback
  }

  static func networkMessage(_ code: URLError.Code) -> String {
    switch code {
    case .timedOut: return L10n.serviceTimedOut
    case .notConnectedToInternet, .networkConnectionLost: return L10n.serviceOffline
    default: return L10n.cantReachBackgroundService
    }
  }

  private static func hubMessage(status: Int, reason: HubError.Reason, fallback: String) -> String {
    switch reason {
    case .badResponse: return L10n.unreadableResponse
    case .unreachable: return L10n.cantReachBackgroundService
    case .timedOut: return L10n.serviceTimedOut
    case .deviceLink: return L10n.deviceConnectionUnavailable
    case .server: return L10n.backgroundServiceFailed
    case .other: break
    }
    switch status {
    case 401, 403: return L10n.serviceAccessExpired
    case 404: return L10n.serviceFeatureUnavailable
    case 409: return L10n.serviceOperationInProgress
    case 413: return L10n.responseTooLarge
    default: return fallback
    }
  }

  private static let internalTerms = #"中枢|线程|提炼|注入|档位|存储操作失败|(?<![a-z0-9_])(?:tier|token|bearer|json|schema|https?|hello|models\.json|sqlite|stack|ocr|hub(?:_id)?|thread|distill|inject|agent|DecodingError|codingPath|debugDescription|NSURLErrorDomain|Error Domain|WebSocket|HPKE|X25519)(?![a-z0-9_])"#

  static func canDisplayServiceMessage(_ message: String) -> Bool {
    message.count <= 120
      && message.range(of: #"\p{Han}"#, options: .regularExpression) != nil
      && message.rangeOfCharacter(from: .controlCharacters) == nil
      && message.range(of: internalTerms, options: [.regularExpression, .caseInsensitive]) == nil
      && message.range(of: #"[（(]\s*\d+\s*[）)]"#, options: .regularExpression) == nil
  }
}
