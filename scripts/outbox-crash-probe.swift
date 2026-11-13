import Foundation
import CryptoKit
import Darwin
import CollectorCore
import AudioStore

let root = URL(fileURLWithPath: CommandLine.arguments[2])
let store = try OutboxStore(dataDirectory: root, key: SymmetricKey(data: Data(repeating: 7, count: 32)))
switch CommandLine.arguments[1] {
case "write":
  let record = Record(device: "synthetic", source: "mac.screen", kind: "text", start: Date(), context: nil, title: "崩溃恢复探针", body: "只在隔离临时目录中的合成内容", capture: .init(method: "probe"))
  _ = try store.append(record)
  // 模拟突然退出，不执行 deinit 或用户态清理。
  _exit(37)
case "ack":
  let restored = store.restore(limit: 1)
  guard restored.records.count == 1, restored.unreadable == 0 else { exit(1) }
  try store.acknowledge(Set(restored.records.map(\.id)))
  _exit(38)
case "empty":
  guard store.count == 0, store.restore(limit: 1).records.isEmpty else { exit(1) }
  print("强制退出恢复 1 条；确认删除后重启 0 条。")
default: exit(2)
}
