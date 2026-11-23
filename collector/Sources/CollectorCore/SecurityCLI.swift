import Foundation

/// 钥匙串只经 `/usr/bin/security` 读写（自签名 app 重新构建后不用再授权）。
/// 写入走 `security -i` 从标准输入读命令，密钥不出现在进程参数里，其他进程用 `ps` 看不到；
/// `-i` 的退出码不可靠，调用方以读回的值为准。
public enum SecurityCLI {
  public struct Failure: Error, Equatable { public let status: Int32 }

  /// 运行 `/usr/bin/security`；10 秒没返回就终止并抛 `Failure(status: -1)`，不无限等待。
  public static func run(_ arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 10) throws -> (status: Int32, text: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let input = stdin.map { _ in Pipe() }
    if let input { process.standardInput = input } else { process.standardInput = FileHandle.nullDevice }
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    try process.run()
    if let input, let stdin {
      input.fileHandleForWriting.write(stdin)
      try? input.fileHandleForWriting.close()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); throw Failure(status: -1) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// `security -i` 的一行写入命令。不带 `-U`：已有条目不覆盖（并发首次创建时先写入者胜出）。
  /// 只接受固定字符集，命令行里不会出现需要转义的内容。
  public static func addGenericPasswordCommand(service: String, account: String, hexValue: String) throws -> Data {
    let name = #/^[A-Za-z0-9._:-]{1,128}$/#
    guard service.wholeMatch(of: name) != nil, account.wholeMatch(of: name) != nil,
          !hexValue.isEmpty, hexValue.count <= 256, hexValue.allSatisfy(\.isHexDigit) else {
      throw Failure(status: -2)
    }
    return Data("add-generic-password -s \(service) -a \(account) -w \(hexValue)\n".utf8)
  }
}
