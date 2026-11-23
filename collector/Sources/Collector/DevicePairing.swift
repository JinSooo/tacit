import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct DeviceSettings: Decodable {
  struct LAN: Decodable {
    let open: Bool
    let port: Int
    let addrs: [String]
  }

  struct Pairing: Decodable { let expiresAt: String }

  enum Role: String, Decodable {
    case collect, view, admin, agent

    var title: String {
      switch self {
      case .collect: "采集"
      case .view: "查看"
      case .admin: "管理"
      case .agent: "AI 工具"
      }
    }
  }

  var displayedDevices: [Device] {
    let visible = devices.filter { $0.role != nil && $0.role != .agent && ["mac", "android"].contains($0.platform) }
    return visible.filter { $0.id == currentDeviceId } + visible.filter { $0.id != currentDeviceId }
  }

  struct Device: Decodable, Identifiable {
    let id: String
    let name: String
    let platform: String
    let pairedAt: String
    let lastSeen: String?
    let records: Int
    let pendingChanges: Int
    var role: Role?

    func offeredRoles(isCurrent: Bool) -> [Role] {
      guard !isCurrent, platform == "mac" else { return [] }
      return switch role {
      case .admin: [.view, .collect]
      case .view: [.collect]
      case .collect: [.view]
      case .agent, nil: []
      }
    }

    func canRemove(isCurrent: Bool) -> Bool {
      !isCurrent && role != nil && role != .agent
    }
  }

  let hubId: String?
  let lan: LAN
  let pairing: Pairing?
  let devices: [Device]
  var currentDeviceId: String?
}

struct DeviceInvitation: Decodable {
  let uri: String
  let expiresAt: String

  var hubId: String? {
    struct Identity: Decodable { let v: Int; let hub_id: String }
    guard let url = URLComponents(string: uri), url.scheme == "tacit", url.host == "pair",
          url.path.isEmpty, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
          let items = url.queryItems, items.count == 1, items[0].name == "d",
          let value = items[0].value, !value.isEmpty,
          value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
          }) else { return nil }
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
          let identity = try? JSONDecoder().decode(Identity.self, from: data),
          identity.v == 1, !identity.hub_id.isEmpty else { return nil }
    return identity.hub_id
  }

  func qrCode(maxPixels: Int = 264) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(uri.utf8)
    filter.correctionLevel = "M"
    guard let code = filter.outputImage, code.extent.width > 0 else { return nil }

    // 四模块静区也按整数倍放大，保留方形模块的硬边。
    let extent = code.extent.insetBy(dx: -4, dy: -4)
    let scale = maxPixels / Int(extent.width)
    guard scale > 0 else { return nil }
    let white = CIImage(color: .white).cropped(to: extent)
    let image = code.composited(over: white).samplingNearest()
      .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
    return CIContext().createCGImage(image, from: image.extent)
  }
}
