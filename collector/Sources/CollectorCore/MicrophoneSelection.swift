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

  /// 默认 ID 通过惰性闭包读取：固定设备模式不会查询系统默认输入。
  public func inputID(devices: [String: UInt32], defaultInput: () -> UInt32?) -> UInt32? {
    let id: UInt32?
    switch self {
    case .system: id = defaultInput()
    case .device(let uid, _): id = devices[uid]
    case .unavailable: id = nil
    }
    return id == 0 ? nil : id
  }

  public var notice: String? {
    switch self {
    case .device(_, true): return "已断开，暂用自带麦克风"
    case .unavailable(let disconnected): return disconnected ? "已断开，找不到自带麦克风" : "找不到自带麦克风"
    default: return nil
    }
  }
}

/// 菜单栏麦克风子菜单和设置页选择器共用的选项，保证两处一致。
public struct MicrophoneChoice: Hashable, Sendable {
  public enum Group: Sendable { case mode, device, notice }
  public let title: String
  /// 写入 micDevice 的值；提示行（已断开、读不到设备）不可选。
  public let value: String
  public let selectable: Bool
  public let group: Group
}

public enum MicrophoneChoices {
  /// devices 为 nil 表示读不到输入设备。
  public static func list(devices: [MicrophoneDevice]?, setting: String) -> [MicrophoneChoice] {
    var choices = [
      MicrophoneChoice(title: L10n.text(zh: "自带麦克风（默认）", en: "Built-in microphone (default)"), value: "builtin", selectable: true, group: .mode),
      MicrophoneChoice(title: L10n.text(zh: "跟随系统默认", en: "Use system default"), value: "system", selectable: true, group: .mode),
    ]
    guard let devices else {
      return choices + [MicrophoneChoice(title: L10n.text(zh: "无法读取输入设备", en: "Couldn't read input devices"), value: "", selectable: false, group: .notice)]
    }
    choices += devices.map { MicrophoneChoice(title: $0.name, value: $0.uid, selectable: true, group: .device) }
    if !choices.contains(where: { $0.value == setting }) {
      choices.append(MicrophoneChoice(title: L10n.text(zh: "所选设备已断开", en: "Selected device disconnected"), value: setting, selectable: false, group: .notice))
    }
    return choices
  }

  /// 录音的附加状态行：去掉"麦克风：设备名"（菜单栏子菜单和设置页选择器已经标出选的是哪个），只留断开回落等提示。
  public static func statusLines(_ lines: [String]) -> [String] {
    lines.compactMap { line in
      guard line.hasPrefix("麦克风：") else { return line }
      guard let r = line.range(of: " · ") else { return nil }
      return "麦克风" + line[r.upperBound...]
    }
  }
}
