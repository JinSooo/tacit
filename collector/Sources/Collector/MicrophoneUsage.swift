import CoreAudio
import Foundation

/// 只查询进程对象，不申请权限、不启动录音；不可用或读取失败时不认定为使用中。
func microphoneInputBundles() -> Set<String> {
  guard #available(macOS 14.2, *) else { return [] }
  let system = AudioObjectID(kAudioObjectSystemObject)
  var property = address(kAudioHardwarePropertyProcessObjectList)
  var size: UInt32 = 0
  let stride = MemoryLayout<AudioObjectID>.stride
  guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
        size > 0, Int(size) % stride == 0 else { return [] }
  var processes = [AudioObjectID](repeating: 0, count: Int(size) / stride)
  let status = processes.withUnsafeMutableBytes {
    AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
  }
  guard status == noErr, Int(size) <= processes.count * stride, Int(size) % stride == 0 else { return [] }

  func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
          size == MemoryLayout<UInt32>.size else { return nil }
    return value
  }

  var bundles = Set<String>()
  for process in processes.prefix(Int(size) / stride) {
    guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1,
          let pid = uint32(process, kAudioProcessPropertyPID),
          pid != UInt32(ProcessInfo.processInfo.processIdentifier) else { continue }
    var property = address(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(process, &property, 0, nil, &size, &value) == noErr,
          let bundle = value?.takeRetainedValue() as String?,
          !bundle.isEmpty, bundle != "dev.record-anything.collector" else { continue }
    bundles.insert(bundle)
  }
  return bundles
}
