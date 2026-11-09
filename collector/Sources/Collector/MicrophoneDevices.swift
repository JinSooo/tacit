import CoreAudio
import Foundation
import CollectorCore

struct InputAudioDevice: Equatable {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let transport: UInt32
  var descriptor: MicrophoneDevice {
    MicrophoneDevice(uid: uid, name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn)
  }
}

/// 只查询属性，不启动设备，不改变系统默认输入。
enum MicrophoneDevices {
  static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  static func inputs() throws -> [InputAudioDevice] {
    var a = property(kAudioHardwarePropertyDevices), size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    try check(AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size), "枚举音频设备")
    guard size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
    let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &a, 0, nil, &size, $0.baseAddress!) }
    try check(status, "读取音频设备列表")
    return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride).compactMap { id in
      var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
      var bytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
            let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName),
            let transport = number(id, kAudioDevicePropertyTransportType) else { return nil }
      return InputAudioDevice(id: id, uid: uid, name: name, transport: transport)
    }.sorted { $0.uid < $1.uid }
  }

  static func defaultInput() -> AudioDeviceID? { number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) }

  private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var a = property(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
  }
  private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = property(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
  }
}

/// 添加和移除使用同一个 block / queue；回调在音频协调队列上执行。
final class MicrophoneDeviceObserver {
  private let queue: DispatchQueue
  private let listener: AudioObjectPropertyListenerBlock
  private var selectors: [AudioObjectPropertySelector] = []
  init(queue: DispatchQueue, changed: @escaping () -> Void) {
    self.queue = queue
    listener = { _, _ in changed() }
  }
  func observe(systemDefault: Bool) throws {
    let wanted = [kAudioHardwarePropertyDevices] + (systemDefault ? [kAudioHardwarePropertyDefaultInputDevice] : [])
    for selector in selectors where !wanted.contains(selector) {
      var a = MicrophoneDevices.property(selector)
      try check(AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, listener), "取消输入设备监听")
      selectors.removeAll { $0 == selector }
    }
    for selector in wanted where !selectors.contains(selector) {
      var a = MicrophoneDevices.property(selector)
      try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, listener), "监听输入设备变化")
      selectors.append(selector)
    }
  }
  func stop() {
    for selector in selectors {
      var a = MicrophoneDevices.property(selector)
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, listener)
    }
    selectors = []
  }
  deinit { stop() }
}
