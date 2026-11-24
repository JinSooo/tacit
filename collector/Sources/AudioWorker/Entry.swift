import Foundation
import AudioStore
import CollectorCore

@main struct Entry {
  static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      var flags: [String: String] = [:]
      guard args.count % 2 == 0 else { throw WorkerError.arguments }
      for i in stride(from: 0, to: args.count, by: 2) {
        guard ["--data-dir", "--device", "--hub", "--models", "--transport", "--remote-delivery"].contains(args[i]), flags[args[i]] == nil else { throw WorkerError.arguments }
        flags[args[i]] = args[i+1]
      }
      guard let path = flags["--data-dir"] ?? ProcessInfo.processInfo.environment["RA_DATA_DIR"],
        let device = flags["--device"], device.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil else { throw WorkerError.arguments }
      let root = URL(fileURLWithPath: path, isDirectory: true)
      let models = flags["--models"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("models")
      let transport: any HubTransport
      if let mode = flags["--transport"] {
        guard mode == "stdio", flags["--hub"] == nil else { throw WorkerError.arguments }
        // 在加载任何原生模型库之前接管 fd 0/1，防止原生库日志污染 JSONL 代理通道。
        transport = StdioHubTransport(channel: StdioLineChannel.captureStandardIO())
      } else {
        guard let hubText = flags["--hub"], let hubURL = URL(string: hubText), ["http", "https"].contains(hubURL.scheme), hubURL.host != nil,
          hubURL.user == nil, hubURL.password == nil else { throw WorkerError.arguments }
        let token = try String(contentsOf: root.appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw WorkerError.arguments }
        transport = Hub(base: hubURL, token: token)
      }
      let remoteDelivery = flags["--remote-delivery"] == "yes" && flags["--transport"] == "stdio"
      let worker = Worker(store: try AudioStore(dataDirectory: root), hub: transport, device: device, remoteDelivery: remoteDelivery) { try Models(directory: models) }
      let failures = try await worker.run()
      if failures > 0 { exit(1) }
    } catch WorkerError.deliveryPaused { return }
    catch { fputs("转写进程失败（参数、同步或本机资源不可用）\n", stderr); exit(1) }
  }
}
