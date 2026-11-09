/// 设备枚举由采集端提供；选择规则不读取系统默认设备，也不打开录音。
public struct MicrophoneDevice: Equatable, Sendable {
  public let uid: String
  public let name: String
  public let isBuiltIn: Bool
  public init(uid: String, name: String, isBuiltIn: Bool) {
    self.uid = uid; self.name = name; self.isBuiltIn = isBuiltIn
  }
}

public enum MicrophoneSelection: Equatable, Sendable {
  case system
  case device(uid: String, fallback: Bool)
  case unavailable(disconnected: Bool)

  public static func resolve(devices: [MicrophoneDevice], setting: String = "builtin") -> Self {
    if setting == "system" { return .system }
    if setting != "builtin", let device = devices.first(where: { $0.uid == setting }) {
      return .device(uid: device.uid, fallback: false)
    }
    let disconnected = setting != "builtin"
    if let device = devices.first(where: { $0.isBuiltIn }) {
      return .device(uid: device.uid, fallback: disconnected)
    }
    return .unavailable(disconnected: disconnected)
  }

  public var notice: String? {
    switch self {
    case .device(_, true): return "已断开，暂用自带麦克风"
    case .unavailable(let disconnected): return disconnected ? "已断开，找不到自带麦克风" : "找不到自带麦克风"
    default: return nil
    }
  }
}
