import CollectorCore
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import Collector

private let hubId = "abcdefghijklmnpqrstuvwxyz2"
private let expiry = "2026-11-19T13:10:00.000Z"

private func invitation(version: Int = 1) -> DeviceInvitation {
  let data = Data("""
    {"v":\(version),"hub_id":"\(hubId)","name":"演示 Mac","pk":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","code":"AAAAAAAAAAAAAAAAAAAAAA","addrs":["192.0.2.5:47824"],"expires_at":"\(expiry)"}
    """.utf8)
  let base64url = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  return DeviceInvitation(uri: "tacit://pair?d=\(base64url)", expiresAt: expiry)
}

@Test func invitationURIExtractsOnlySupportedIdentity() {
  let valid = invitation()
  #expect(valid.hubId == hubId)
  #expect(invitation(version: 2).hubId == nil)
  for uri in [
    "https://pair?d=e30", "tacit://timeline?d=e30", "tacit://pair?d=%2B", "tacit://pair?d=broken",
    valid.uri + "&d=e30", valid.uri + "#extra", valid.uri.replacingOccurrences(of: "://pair", with: "://user@pair"),
  ] {
    #expect(DeviceInvitation(uri: uri, expiresAt: expiry).hubId == nil)
  }
}

@Test func invitationQRCodeIsPixelAlignedAndDecodable() throws {
  let invite = invitation()
  let filter = CIFilter.qrCodeGenerator()
  filter.message = Data(invite.uri.utf8)
  filter.correctionLevel = "M"
  let sizeWithMargin = Int(try #require(filter.outputImage).extent.width) + 8
  let qr = try #require(invite.qrCode())
  #expect(qr.width == sizeWithMargin * (264 / sizeWithMargin))
  #expect(qr.height == qr.width)

  let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
  let image = CIImage(cgImage: qr)
  let decoded = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
  #expect(decoded == [invite.uri])

  var pixels = [UInt8](repeating: 0, count: qr.width * qr.height)
  CIContext().render(image, toBitmap: &pixels, rowBytes: qr.width, bounds: image.extent,
                     format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
  #expect(Set(pixels) == [0, 255])
}

private let devicesJSON = """
  {
    "hub_id":"\(hubId)",
    "lan":{"open":true,"port":47824,"addrs":["192.0.2.5:47824"]},
    "pairing":{"expires_at":"\(expiry)"},
    "devices":[
      {"id":"android-fixture1","name":"演示手机","platform":"android",
       "paired_at":"2026-11-19T12:55:00Z","last_seen":"2026-11-19T13:00:00Z","records":42,"pending_changes":2},
      {"id":"android-fixture2","name":"备用手机","platform":"android",
       "paired_at":"2026-11-19T12:56:00Z","last_seen":null,"records":0,"pending_changes":0}
    ]
  }
  """

@Test func deviceManagementUsesContractRoutesAndDecodesSettings() async throws {
  let api = stubAPI(host: "current.test")
  let settings = try #require(try await api.deviceSettings())
  #expect(settings.hubId == hubId)
  #expect(settings.lan.open)
  #expect(settings.lan.port == 47824)
  #expect(settings.lan.addrs == ["192.0.2.5:47824"])
  #expect(settings.pairing?.expiresAt == expiry)
  #expect(settings.devices.count == 2)
  let phone = try #require(settings.devices.first)
  #expect(phone.id == "android-fixture1")
  #expect(phone.name == "演示手机")
  #expect(phone.platform == "android")
  #expect(phone.pairedAt == "2026-11-19T12:55:00Z")
  #expect(phone.lastSeen == "2026-11-19T13:00:00Z")
  #expect(phone.records == 42)
  #expect(phone.pendingChanges == 2)
  #expect(settings.devices.last?.lastSeen == nil)

  let invite = try await api.createDeviceInvitation()
  #expect(invite.uri == invitation().uri)
  #expect(invite.expiresAt == expiry)
  try await api.cancelDeviceInvitation()
  try await api.removeDevice(phone.id)
}

@Test func oldDeviceSettingsEndpointReturnsNilOn404() async throws {
  #expect(try await stubAPI(host: "legacy.test").deviceSettings() == nil)
  await #expect(throws: HubError.self) {
    try await stubAPI(host: "unavailable.test").deviceSettings()
  }
}

@MainActor @Test func discoveryPublishesOnlyWhileLANIsOpenAndReplacesChangedRegistration() throws {
  let advertiser = AdvertisementSpy()
  let discovery = DeviceDiscovery(advertiser: advertiser)
  let settings = try HubJSON.decoder().decode(DeviceSettings.self, from: Data(devicesJSON.utf8))
  let closed = DeviceSettings(hubId: hubId, lan: .init(open: false, port: 47824, addrs: []), pairing: nil, devices: [])
  let missingId = DeviceSettings(hubId: nil, lan: settings.lan, pairing: settings.pairing, devices: [])
  let changed = DeviceSettings(hubId: hubId, lan: .init(open: true, port: 47825, addrs: []), pairing: nil, devices: [])
  discovery.update(closed)
  discovery.update(missingId)
  #expect(advertiser.events.isEmpty)

  discovery.update(missingId, invitationHubId: invitation().hubId)
  discovery.update(settings)
  discovery.update(changed)
  discovery.update(closed)
  discovery.update(settings)
  discovery.update(nil)
  #expect(advertiser.events == [
    .publish(DeviceAdvertisement(hubId: hubId, port: 47824)), .stop,
    .publish(DeviceAdvertisement(hubId: hubId, port: 47825)), .stop,
    .publish(DeviceAdvertisement(hubId: hubId, port: 47824)), .stop,
  ])
}

@MainActor private final class AdvertisementSpy: DeviceAdvertising {
  enum Event: Equatable { case publish(DeviceAdvertisement), stop }
  private(set) var events: [Event] = []
  private(set) var advertisement: DeviceAdvertisement?

  func publish(_ advertisement: DeviceAdvertisement) {
    events.append(.publish(advertisement))
    self.advertisement = advertisement
  }

  func stop() {
    events.append(.stop)
    advertisement = nil
  }
}

private func stubAPI(host: String) -> HubAPI {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [DeviceSettingsStub.self]
  return HubAPI(base: { URL(string: "http://\(host)")! }, token: { "fixture-token" }, configuration: configuration)
}

private final class DeviceSettingsStub: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let status: Int
    let body: String
    switch (url.host, request.httpMethod, url.path, request.value(forHTTPHeaderField: "Authorization")) {
    case ("current.test", "GET", "/v1/settings/devices", "Bearer fixture-token"):
      (status, body) = (200, devicesJSON)
    case ("current.test", "POST", "/v1/settings/devices/pairing", "Bearer fixture-token"):
      (status, body) = (200, """
        {"uri":"\(invitation().uri)","expires_at":"\(expiry)"}
        """)
    case ("current.test", "DELETE", "/v1/settings/devices/pairing", "Bearer fixture-token"),
         ("current.test", "DELETE", "/v1/settings/devices/android-fixture1", "Bearer fixture-token"):
      (status, body) = (204, "")
    case ("legacy.test", "GET", "/v1/settings/devices", "Bearer fixture-token"):
      (status, body) = (404, "{\"error\":\"not found\"}")
    default:
      (status, body) = (503, "{\"error\":\"service unavailable\"}")
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
