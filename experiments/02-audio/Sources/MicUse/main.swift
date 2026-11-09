// 列出此刻正在使用音频输入/输出的进程（Core Audio 进程对象，macOS 14+）。只读，不录音。
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32? {
  var a = addr(s), v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
  return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func bundle(_ obj: AudioObjectID) -> String {
  var a = addr(kAudioProcessPropertyBundleID), v: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else { return "?" }
  return s as String
}
var a = addr(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
var st = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
print("进程对象 \(ids.count) 个，OSStatus=\(st)")
for id in ids {
  let input = u32(id, kAudioProcessPropertyIsRunningInput) ?? 0, output = u32(id, kAudioProcessPropertyIsRunningOutput) ?? 0
  if input != 0 || output != 0 { print("pid=\(u32(id, kAudioProcessPropertyPID).map(String.init) ?? "?") input=\(input) output=\(output) \(bundle(id))") }
}
