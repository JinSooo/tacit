import Foundation

/// 官网 `latest.json` 里 Mac 版的最新版本。只读版本号和下载页，不带任何本机信息。
public struct UpdateManifest: Equatable, Sendable {
  public static let url = URL(string: "https://tacit.jinso.top/latest.json")!
  public let version: String
  public let page: URL

  /// 只接受 `{"mac":{"version":"x.y.z","url":"https://…"}}`，且版本比当前新；其他一律当作没有更新。
  public static func newer(than current: String?, in data: Data) -> UpdateManifest? {
    struct File: Decodable { struct Mac: Decodable { let version: String; let url: String }; let mac: Mac }
    guard let current, let parts = components(current),
          let file = try? JSONDecoder().decode(File.self, from: data),
          let latest = components(file.mac.version),
          let page = URL(string: file.mac.url), page.scheme == "https", page.host != nil,
          latest.lexicographicallyPrecedes(parts) == false, latest != parts else { return nil }
    return UpdateManifest(version: file.mac.version, page: page)
  }

  /// `0.6.4` → [0, 6, 4]；少于三段补 0，非数字（开发版等）返回 nil。
  static func components(_ version: String) -> [Int]? {
    let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(pieces.count) else { return nil }
    var numbers: [Int] = []
    for piece in pieces {
      guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let n = Int(piece), n >= 0 else { return nil }
      numbers.append(n)
    }
    return numbers + Array(repeating: 0, count: 4 - numbers.count)
  }
}
