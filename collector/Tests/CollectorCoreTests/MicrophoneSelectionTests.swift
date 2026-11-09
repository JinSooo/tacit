import Testing
@testable import CollectorCore

private let builtinMic = MicrophoneDevice(uid: "synthetic-builtin", name: "自带麦克风", isBuiltIn: true)
private let headsetMic = MicrophoneDevice(uid: "synthetic-headset", name: "耳机", isBuiltIn: false)

@Test func defaultMicrophoneAvoidsBluetoothEvenWhenItIsFirst() {
  #expect(MicrophoneSelection.resolve(devices: [headsetMic, builtinMic]) == .device(uid: builtinMic.uid, fallback: false))
}
@Test func missingBuiltinNeverUsesSystemDefault() {
  let result = MicrophoneSelection.resolve(devices: [headsetMic])
  #expect(result == .unavailable(disconnected: false))
  #expect(result.notice == "找不到自带麦克风")
  #expect(MicrophoneSelection.resolve(devices: []) == .unavailable(disconnected: false))
}
@Test func explicitMicrophoneDisconnectsAndReconnects() {
  #expect(MicrophoneSelection.resolve(devices: [headsetMic, builtinMic], setting: headsetMic.uid) == .device(uid: headsetMic.uid, fallback: false))
  let fallback = MicrophoneSelection.resolve(devices: [builtinMic], setting: headsetMic.uid)
  #expect(fallback == .device(uid: builtinMic.uid, fallback: true))
  #expect(fallback.notice == "已断开，暂用自带麦克风")
  #expect(MicrophoneSelection.resolve(devices: [], setting: headsetMic.uid) == .unavailable(disconnected: true))
}
@Test func systemMicrophoneDoesNotOverrideDevice() {
  #expect(MicrophoneSelection.resolve(devices: [headsetMic, builtinMic], setting: "system") == .system)
  #expect(MicrophoneSelection.resolve(devices: [], setting: "system") == .system)
}
