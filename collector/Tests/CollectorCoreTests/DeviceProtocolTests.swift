import CryptoKit
import Foundation
import Testing
@testable import CollectorCore

private struct FixtureFile: Decodable {
  struct KeyMaterial: Decodable {
    let hub_id: String?
    let device_id: String?
    let private_key_hex: String
    let public_key_base64url: String
  }

  struct RequestVector: Decodable {
    let mode: String
    let info_utf8: String
    let aad_utf8: String
    let ephemeral_ikm_hex: String
    let plaintext_json_utf8: String
    let envelope: DeviceRequestEnvelope
  }

  struct ResponseVector: Decodable {
    let mode: String
    let info_utf8: String
    let aad_utf8: String
    let ephemeral_ikm_hex: String
    let plaintext_json_utf8: String
    let envelope: DeviceResponseEnvelope
  }

  struct PairSample: Decodable {
    let request: RequestVector
    let response: ResponseVector
  }

  let v: Int
  let hub: KeyMaterial
  let device: KeyMaterial
  let pairing: PairSample
  let sync: PairSample
}

/// RFC 9180 §7.1.3 DeriveKeyPair for DHKEM(X25519, HKDF-SHA256) (KEM ID 0x0020).
private func rfc9180DeriveX25519KeyPair(ikm: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
  var suiteID = Data("KEM".utf8)
  suiteID.append(contentsOf: [0x00, 0x20])

  var labeledIKM = Data("HPKE-v1".utf8)
  labeledIKM.append(suiteID)
  labeledIKM.append(Data("dkp_prk".utf8))
  labeledIKM.append(ikm)
  let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: labeledIKM), salt: Data())

  var labeledInfo = Data([0x00, 0x20]) // I2OSP(32, 2)
  labeledInfo.append(Data("HPKE-v1".utf8))
  labeledInfo.append(suiteID)
  labeledInfo.append(Data("sk".utf8))
  let sk = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: labeledInfo, outputByteCount: 32)
  let skData = sk.withUnsafeBytes { Data($0) }
  return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: skData)
}

private func loadDeviceEnvelopeFixture() throws -> FixtureFile {
  let file = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../schema/fixtures/device-envelope.json")
    .standardizedFileURL
  let data = try Data(contentsOf: file)
  return try JSONDecoder().decode(FixtureFile.self, from: data)
}

private actor StubDeviceTransport: DeviceTransport {
  let maxEnvelopeBytes: Int
  private let handler: @Sendable (SealedDeviceRequest) async throws -> DeviceTransportResponse
  private(set) var requests: [SealedDeviceRequest] = []

  init(
    maxEnvelopeBytes: Int = DeviceProtocol.maxEnvelopeBytes,
    handler: @escaping @Sendable (SealedDeviceRequest) async throws -> DeviceTransportResponse
  ) {
    self.maxEnvelopeBytes = maxEnvelopeBytes
    self.handler = handler
  }

  func send(_ request: SealedDeviceRequest) async throws -> DeviceTransportResponse {
    requests.append(request)
    return try await handler(request)
  }
}

private final class FailingKeyStore: DeviceKeyStore, @unchecked Sendable {
  struct SimulatedError: Error {}
  func readPrivateKey() throws -> Data? { throw SimulatedError() }
  func writePrivateKey(_ rawRepresentation: Data) throws { throw SimulatedError() }
  func deletePrivateKey() throws { throw SimulatedError() }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

@Test func opensAndReproducesHubInteropVectors() throws {
  let fixture = try loadDeviceEnvelopeFixture()
  #expect(fixture.v == DeviceProtocol.version)

  let hubPrivateRaw = try #require(DeviceProtocol.hexDecode(fixture.hub.private_key_hex))
  let hubPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hubPrivateRaw)
  let hubPublic = try DeviceEnvelope.publicKey(base64URL: fixture.hub.public_key_base64url)
  #expect(DeviceEnvelope.publicKeyBase64URL(hubPrivate.publicKey) == fixture.hub.public_key_base64url)
  #expect(DeviceProtocol.hubID(for: hubPublic) == fixture.hub.hub_id)

  let devicePrivateRaw = try #require(DeviceProtocol.hexDecode(fixture.device.private_key_hex))
  let devicePrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: devicePrivateRaw)
  let devicePublic = try DeviceEnvelope.publicKey(base64URL: fixture.device.public_key_base64url)
  #expect(DeviceEnvelope.publicKeyBase64URL(devicePrivate.publicKey) == fixture.device.public_key_base64url)

  for (name, sample) in [("pairing", fixture.pairing), ("sync", fixture.sync)] {
    let req = sample.request
    let expectedDeviceID = name == "sync" ? fixture.device.device_id : nil
    #expect(req.info_utf8 == DeviceProtocol.requestInfo)
    #expect(req.aad_utf8 == (expectedDeviceID ?? ""))
    #expect(req.envelope.v == 1)
    #expect(req.envelope.device == expectedDeviceID)

    // 1. Swift 能解开中枢生成的请求向量（base 与 auth 模式）。
    let openedRequest = try DeviceEnvelope.openRequestEnvelope(
      req.envelope,
      recipientPrivateKey: hubPrivate,
      senderPublicKey: req.mode == "auth" ? devicePublic : nil
    )
    #expect(String(data: openedRequest, encoding: .utf8) == req.plaintext_json_utf8)

    // 2. 用 ephemeral_ikm 经 RFC 9180 DeriveKeyPair 复现请求封装公钥 enc 及除密文外全部字段。
    let reqIKM = try #require(DeviceProtocol.hexDecode(req.ephemeral_ikm_hex))
    let derivedReqEphemeral = try rfc9180DeriveX25519KeyPair(ikm: reqIKM)
    #expect(DeviceEnvelope.publicKeyBase64URL(derivedReqEphemeral.publicKey) == req.envelope.enc)

    // 3. Swift 封装同明文并校验能被中枢侧逻辑解开，且线上非密文字段一致。
    let swiftSealedReq = try DeviceEnvelope.sealRequestPlaintext(
      Data(req.plaintext_json_utf8.utf8),
      deviceID: expectedDeviceID,
      hubPublicKey: hubPublic,
      senderPrivateKey: req.mode == "auth" ? devicePrivate : nil
    )
    #expect(swiftSealedReq.v == req.envelope.v)
    #expect(swiftSealedReq.device == req.envelope.device)
    let reopenedReq = try DeviceEnvelope.openRequestEnvelope(
      swiftSealedReq,
      recipientPrivateKey: hubPrivate,
      senderPublicKey: req.mode == "auth" ? devicePublic : nil
    )
    #expect(String(data: reopenedReq, encoding: .utf8) == req.plaintext_json_utf8)

    // 4. Swift 能解开中枢生成的回复向量（auth 模式、tacit-device-v1/response、AAD 为请求 nonce）。
    let res = sample.response
    #expect(res.mode == "auth")
    #expect(res.info_utf8 == DeviceProtocol.responseInfo)
    #expect(res.envelope.v == 1)
    let openedResponse = try DeviceEnvelope.openResponseEnvelope(
      res.envelope,
      requestNonce: res.aad_utf8,
      recipientPrivateKey: devicePrivate,
      hubPublicKey: hubPublic
    )
    #expect(String(data: openedResponse, encoding: .utf8) == res.plaintext_json_utf8)

    let responseWire = try JSONEncoder().encode(res.envelope)
    let payload = try DeviceEnvelope.openResponse(
      wireData: responseWire,
      requestNonce: res.aad_utf8,
      recipientPrivateKey: devicePrivate,
      hubPublicKey: hubPublic
    )
    #expect(payload.status == 200)

    // 5. 用 ephemeral_ikm 复现回复封装公钥 enc。
    let resIKM = try #require(DeviceProtocol.hexDecode(res.ephemeral_ikm_hex))
    let derivedResEphemeral = try rfc9180DeriveX25519KeyPair(ikm: resIKM)
    #expect(DeviceEnvelope.publicKeyBase64URL(derivedResEphemeral.publicKey) == res.envelope.enc)
  }
}

@Test func envelopeRejectsTamperingWrongKeyAndMissingDeviceNull() throws {
  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let deviceKey = Curve25519.KeyAgreement.PrivateKey()
  let intruderKey = Curve25519.KeyAgreement.PrivateKey()

  // 配对信封必须显式输出 "device": null。
  let pairSealed = try DeviceEnvelope.makeRequest(
    op: "pair",
    body: ["code": .string(DeviceProtocol.base64URLEncode(Data(repeating: 0x11, count: 16)))],
    deviceID: nil,
    hubPublicKey: hubKey.publicKey,
    senderPrivateKey: nil
  )
  let rawJSON = try #require(try JSONSerialization.jsonObject(with: pairSealed.wireData) as? [String: Any])
  #expect(rawJSON["device"] is NSNull)

  // 缺少 device 字段的 JSON 必须解码失败。
  let missingDeviceJSON = Data(#"{"v":1,"enc":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ct":"AAAAAAAAAAAAAAAAAAAAAA"}"#.utf8)
  #expect(throws: Error.self) {
    _ = try JSONDecoder().decode(DeviceRequestEnvelope.self, from: missingDeviceJSON)
  }

  // auth 模式请求校验：换错发送方公钥、篡改 device(AAD) 或篡改密文均失败。
  let authSealed = try DeviceEnvelope.makeRequest(
    op: "sync",
    body: ["cursor": .int(0)],
    deviceID: "mac-abcd2345",
    hubPublicKey: hubKey.publicKey,
    senderPrivateKey: deviceKey
  )
  #expect(throws: DeviceClientError.self) {
    _ = try DeviceEnvelope.openRequestEnvelope(
      authSealed.envelope,
      recipientPrivateKey: hubKey,
      senderPublicKey: intruderKey.publicKey
    )
  }
  let tamperedAAD = DeviceRequestEnvelope(
    v: 1,
    device: "mac-zzzz2345",
    enc: authSealed.envelope.enc,
    ct: authSealed.envelope.ct
  )
  #expect(throws: DeviceClientError.self) {
    _ = try DeviceEnvelope.openRequestEnvelope(
      tamperedAAD,
      recipientPrivateKey: hubKey,
      senderPublicKey: deviceKey.publicKey
    )
  }

  // 响应 AAD（请求 nonce）不匹配必须解密失败。
  let responseEnv = try DeviceEnvelope.sealResponsePlaintext(
    Data(#"{"status":200,"body":{"ok":true}}"#.utf8),
    requestNonce: authSealed.nonce,
    senderPrivateKey: hubKey,
    recipientPublicKey: deviceKey.publicKey
  )
  let otherNonce = DeviceProtocol.base64URLEncode(Data(repeating: 0x55, count: 16))
  #expect(throws: DeviceClientError.self) {
    _ = try DeviceEnvelope.openResponseEnvelope(
      responseEnv,
      requestNonce: otherNonce,
      recipientPrivateKey: deviceKey,
      hubPublicKey: hubKey.publicKey
    )
  }

  // 非对象请求体被拒绝。
  #expect(throws: DeviceClientError.invalidRequest("请求 body 必须是 JSON 对象")) {
    _ = try DeviceEnvelope.makeRequest(
      op: "sync",
      body: [1, 2, 3],
      deviceID: "mac-abcd2345",
      hubPublicKey: hubKey.publicKey,
      senderPrivateKey: deviceKey
    )
  }
}

@Test func parsesAndValidatesPairingInvitation() throws {
  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let hubID = DeviceProtocol.hubID(for: hubKey.publicKey)
  let pk = DeviceEnvelope.publicKeyBase64URL(hubKey.publicKey)
  let code = DeviceProtocol.base64URLEncode(Data(repeating: 0x22, count: 16))
  let expiry = try #require(DeviceProtocol.parseRFC3339("2030-01-01T00:00:00Z"))
  let relaySpace = DeviceProtocol.base64URLEncode(Data(repeating: 0x33, count: 16))
  let relayUp = DeviceProtocol.base64URLEncode(Data(repeating: 0x44, count: 16))
  let relayDown = DeviceProtocol.base64URLEncode(Data(repeating: 0x55, count: 16))
  let relayToken = String(repeating: "a", count: 32)

  func makeURI(
    hubID: String = hubID,
    expiresAt: String = "2030-01-01T00:00:00Z",
    relayURL: String? = "https://relay.example.net/",
    role: String? = "admin"
  ) throws -> String {
    var payload: [String: DeviceJSON] = [
      "v": .int(1),
      "hub_id": .string(hubID),
      "name": .string("测试 Mac"),
      "pk": .string(pk),
      "code": .string(code),
      "addrs": .array([
        .string("192.0.2.1:47824"),
        .string("https://mac.example.net/"),
        .string("192.0.2.1:47824"),
        .string("http://user@bad.example.net"),
        .string("[fd00::1]:47824"),
      ]),
      "expires_at": .string(expiresAt),
    ]
    if let relayURL {
      payload["relay"] = .object([
        "url": .string(relayURL),
        "space": .string(relaySpace),
        "up": .string(relayUp),
        "down": .string(relayDown),
        "token": .string(relayToken),
      ])
    }
    if let role {
      payload["role"] = .string(role)
    }
    let data = try JSONEncoder().encode(DeviceJSON.object(payload))
    return "tacit://pair?d=\(DeviceProtocol.base64URLEncode(data))"
  }

  let invite = try DevicePairingInvitation.parse(try makeURI(), now: expiry.addingTimeInterval(-1))
  #expect(invite.hubID == hubID)
  #expect(invite.hubName == "测试 Mac")
  #expect(invite.code == code)
  #expect(invite.role == "admin")
  #expect(invite.addresses.map(\.absoluteString) == [
    "http://192.0.2.1:47824",
    "https://mac.example.net",
    "http://[fd00::1]:47824",
  ])
  #expect(invite.relay?.url == "https://relay.example.net")
  #expect(invite.relay?.space == relaySpace)

  // 过期邀请抛出 inviteExpired。
  #expect(throws: DeviceClientError.inviteExpired) {
    _ = try DevicePairingInvitation.parse(try makeURI(), now: expiry)
  }

  // hub_id 与公钥不匹配被拒绝。
  #expect(throws: DeviceClientError.invalidInvitation("hub_id 与公钥不匹配")) {
    _ = try DevicePairingInvitation.parse(try makeURI(hubID: "aaaaaaaaaaaaaaaaaaaaaaaaaa"), now: expiry.addingTimeInterval(-1))
  }

  // 公网非 HTTPS 信箱地址被拒绝。
  #expect(throws: DeviceClientError.invalidInvitation("信箱地址无效")) {
    _ = try DevicePairingInvitation.parse(try makeURI(relayURL: "http://relay.example.net"), now: expiry.addingTimeInterval(-1))
  }

  // 非法 origin 归一化检查。
  #expect(DevicePairingInvitation.normalizeOrigin("http://user@mac.example.net") == nil)
  #expect(DevicePairingInvitation.normalizeOrigin("https://mac.example.net/extra") == nil)
  #expect(DevicePairingInvitation.normalizeOrigin("https://mac.example.net?x=1") == nil)

  // 设备编号（含 6.10.1 扩展前缀）、base64url 与 RFC 3339 严格校验。
  for valid in ["android-aebagbaf", "mac-k7m2p6q4", "agent-234567ab", "linux-abcdefgh", "windows-zzzz2345"] {
    #expect(DeviceProtocol.isValidDeviceID(valid))
  }
  for invalid in ["mac-12345678", "mac-short", "ios-abcdefgh", "mac-ABCDEFGH", "android-abcdefgh9"] {
    #expect(!DeviceProtocol.isValidDeviceID(invalid))
  }
  #expect(DeviceProtocol.base64URLDecode("AQ==") == nil)
  #expect(DeviceProtocol.base64URLDecode("AB") == nil) // 非规范尾位（0x00 的规范编码应为 AA）
  #expect(DeviceProtocol.base64URLDecode("AA") == Data([0x00]))
  #expect(DeviceProtocol.parseRFC3339("2026-02-30T00:00:00Z") == nil)
  #expect(DeviceProtocol.parseRFC3339("2026-11-23T08:00:00+08:00") != nil)
}

@Test func pairsAndSwitchesToAuthenticatedMode() async throws {
  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let hubID = DeviceProtocol.hubID(for: hubKey.publicKey)
  let code = DeviceProtocol.base64URLEncode(Data(repeating: 0x77, count: 16))
  let now = try #require(DeviceProtocol.parseRFC3339("2026-11-23T08:00:00Z"))
  let expiry = "2026-11-23T08:10:00Z"

  let invitePayload: [String: DeviceJSON] = [
    "v": .int(1),
    "hub_id": .string(hubID),
    "name": .string("合成中枢"),
    "pk": .string(DeviceEnvelope.publicKeyBase64URL(hubKey.publicKey)),
    "code": .string(code),
    "addrs": .array([.string("127.0.0.1:47824")]),
    "expires_at": .string(expiry),
  ]
  let inviteURI = "tacit://pair?d=\(DeviceProtocol.base64URLEncode(try JSONEncoder().encode(DeviceJSON.object(invitePayload))))"
  let invitation = try DevicePairingInvitation.parse(inviteURI, now: now)

  let registeredKeyBox = InMemoryDeviceKeyStore()
  let assignedDeviceID = "mac-abcd2345"

  let transport = StubDeviceTransport { sealed in
    if sealed.envelope.device == nil {
      // base 模式配对请求。
      let plaintext = try DeviceEnvelope.openRequestEnvelope(sealed.envelope, recipientPrivateKey: hubKey)
      let json = try JSONDecoder().decode(DeviceJSON.self, from: plaintext)
      #expect(json["op"]?.stringValue == "pair")
      #expect(json["nonce"]?.stringValue == sealed.nonce)
      #expect(json["body"]?["code"]?.stringValue == code)
      #expect(json["body"]?["platform"]?.stringValue == "mac")
      let devicePK = try DeviceEnvelope.publicKey(base64URL: try #require(json["body"]?["device_pk"]?.stringValue))
      // 暂存设备公钥字节以验证后续 auth 请求。
      try registeredKeyBox.writePrivateKey(devicePK.rawRepresentation)

      let replyPlain = try JSONEncoder().encode(DeviceJSON.object([
        "status": .int(200),
        "body": .object([
          "device_id": .string(assignedDeviceID),
          "hub_id": .string(hubID),
          "name": .string("测试 Mac 采集端"),
        ]),
      ]))
      let replyEnv = try DeviceEnvelope.sealResponsePlaintext(
        replyPlain,
        requestNonce: sealed.nonce,
        senderPrivateKey: hubKey,
        recipientPublicKey: devicePK
      )
      return DeviceTransportResponse(statusCode: 200, body: try JSONEncoder().encode(replyEnv))
    } else {
      // auth 模式已配对请求。
      #expect(sealed.envelope.device == assignedDeviceID)
      let storedPKRaw = try #require(try registeredKeyBox.readPrivateKey())
      let devicePK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: storedPKRaw)
      let plaintext = try DeviceEnvelope.openRequestEnvelope(
        sealed.envelope,
        recipientPrivateKey: hubKey,
        senderPublicKey: devicePK
      )
      let json = try JSONDecoder().decode(DeviceJSON.self, from: plaintext)
      #expect(json["op"]?.stringValue == "sync")
      #expect(json["body"]?["cursor"]?.intValue == 0)

      let replyPlain = try JSONEncoder().encode(DeviceJSON.object([
        "status": .int(200),
        "body": .object([
          "changes": .array([]),
          "cursor": .int(0),
          "more": .bool(false),
        ]),
      ]))
      let replyEnv = try DeviceEnvelope.sealResponsePlaintext(
        replyPlain,
        requestNonce: sealed.nonce,
        senderPrivateKey: hubKey,
        recipientPublicKey: devicePK
      )
      return DeviceTransportResponse(statusCode: 200, body: try JSONEncoder().encode(replyEnv))
    }
  }

  let keyStore = InMemoryDeviceKeyStore()
  let client = DeviceClient(invitation: invitation, keyStore: keyStore, transport: transport, clock: { now })
  let paired = try await client.pair(invitation: invitation, deviceName: "测试 Mac 采集端", platform: .mac)
  #expect(paired.deviceID == assignedDeviceID)
  #expect(paired.hubID == hubID)
  #expect(await client.deviceID == assignedDeviceID)
  #expect(try keyStore.readPrivateKey()?.count == 32)

  struct SyncResponse: Decodable, Equatable {
    let cursor: Int
    let more: Bool
  }
  let syncReply = try await client.send(op: "sync", body: ["cursor": .int(0)], as: SyncResponse.self)
  #expect(syncReply == SyncResponse(cursor: 0, more: false))
  #expect(await transport.requests.count == 2)
  #expect(await transport.requests[0].envelope.device == nil)
  #expect(await transport.requests[1].envelope.device == assignedDeviceID)
}

@Test func classifies62ErrorsAndLatchesDeviceRemoved() async throws {
  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let deviceKey = Curve25519.KeyAgreement.PrivateKey()

  // 401 已移除：抛出 deviceRemoved 并锁定后续不再发请求。
  let removedTransport = StubDeviceTransport { _ in
    DeviceTransportResponse(statusCode: 401, body: Data(#"{"error":"设备未配对或已移除"}"#.utf8))
  }
  let removedClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: removedTransport
  )
  await #expect(throws: DeviceClientError.deviceRemoved(message: "设备未配对或已移除")) {
    _ = try await removedClient.send(op: "sync", body: ["cursor": .int(0)])
  }
  #expect(await removedClient.isRemoved == true)
  await #expect(throws: DeviceClientError.deviceRemoved(message: nil)) {
    _ = try await removedClient.send(op: "relay")
  }
  #expect(await removedTransport.requests.count == 1)

  // 413 服务端明文错误。
  let tooLargeTransport = StubDeviceTransport { _ in
    DeviceTransportResponse(statusCode: 413, body: Data(#"{"error":"信封超过 8 MiB"}"#.utf8))
  }
  let tooLargeClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: tooLargeTransport
  )
  await #expect(throws: DeviceClientError.envelopeTooLarge(message: "信封超过 8 MiB")) {
    _ = try await tooLargeClient.send(op: "ingest", body: ["records": .array([])])
  }

  // 客户端本地超限拦截（不触达传输层）。
  let tinyLimitTransport = StubDeviceTransport(maxEnvelopeBytes: 64) { _ in
    DeviceTransportResponse(statusCode: 200, body: Data())
  }
  let tinyLimitClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: tinyLimitTransport
  )
  await #expect(throws: DeviceClientError.envelopeTooLarge(message: nil)) {
    _ = try await tinyLimitClient.send(op: "sync", body: ["cursor": .int(0)])
  }
  #expect(await tinyLimitTransport.requests.isEmpty)

  // 503 数据库忙。
  let busyTransport = StubDeviceTransport { _ in
    DeviceTransportResponse(statusCode: 503, body: Data(#"{"error":"数据库忙，稍后再试"}"#.utf8))
  }
  let busyClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: busyTransport
  )
  await #expect(throws: DeviceClientError.hubBusy(message: "数据库忙，稍后再试")) {
    _ = try await busyClient.send(op: "sync", body: ["cursor": .int(0)])
  }

  // 400 明文错误。
  let badEnvelopeTransport = StubDeviceTransport { _ in
    DeviceTransportResponse(statusCode: 400, body: Data(#"{"error":"信封格式错误"}"#.utf8))
  }
  let badEnvelopeClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: badEnvelopeTransport
  )
  await #expect(throws: DeviceClientError.plaintextError(status: 400, message: "信封格式错误")) {
    _ = try await badEnvelopeClient.send(op: "sync", body: ["cursor": .int(0)])
  }

  // HTTP 200 加密业务错误（例如 403 权限不足或邀请无效）。
  let opErrorTransport = StubDeviceTransport { sealed in
    let replyPlain = Data(#"{"status":403,"body":{"error":"配对邀请无效或已过期"}}"#.utf8)
    let replyEnv = try DeviceEnvelope.sealResponsePlaintext(
      replyPlain,
      requestNonce: sealed.nonce,
      senderPrivateKey: hubKey,
      recipientPublicKey: deviceKey.publicKey
    )
    return DeviceTransportResponse(statusCode: 200, body: try JSONEncoder().encode(replyEnv))
  }
  let opErrorClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(privateKey: deviceKey),
    transport: opErrorTransport
  )
  await #expect(throws: DeviceClientError.operationError(op: "sync", status: 403, message: "配对邀请无效或已过期")) {
    _ = try await opErrorClient.send(op: "sync", body: ["cursor": .int(0)])
  }

  // KeyStore 错误传播 & 已配对客户端缺私钥不静默生成新密钥。
  let failingKeyClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: FailingKeyStore(),
    transport: busyTransport
  )
  await #expect(throws: DeviceClientError.self) {
    _ = try await failingKeyClient.send(op: "sync", body: ["cursor": .int(0)])
  }
  let missingKeyClient = try DeviceClient(
    hubPublicKey: hubKey.publicKey,
    deviceID: "mac-abcd2345",
    keyStore: InMemoryDeviceKeyStore(),
    transport: busyTransport
  )
  await #expect(throws: DeviceClientError.invalidKey("密钥存储中缺少设备私钥")) {
    _ = try await missingKeyClient.send(op: "sync", body: ["cursor": .int(0)])
  }
}

@Test func directTransportPostsEnvelopeAndChecksHello() async throws {
  let hubKey = Curve25519.KeyAgreement.PrivateKey()
  let deviceKey = Curve25519.KeyAgreement.PrivateKey()
  let hubID = DeviceProtocol.hubID(for: hubKey.publicKey)

  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockURLProtocol.self]
  let session = URLSession(configuration: config)
  defer { MockURLProtocol.handler = nil }

  MockURLProtocol.handler = { request in
    let url = try #require(request.url)
    if request.httpMethod == "GET" && url.path == "/v1/device/hello" {
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, Data(#"{"hub_id":"\#(hubID)","v":1}"#.utf8))
    }
    if request.httpMethod == "POST" && url.path == "/v1/device" {
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, Data(#"{"v":1,"enc":"ok","ct":"ok"}"#.utf8))
    }
    let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
    return (response, Data())
  }

  let transport = try DirectDeviceTransport.loopback(port: 47824, session: session)
  #expect(transport.origin.absoluteString == "http://127.0.0.1:47824")
  let hello = try await transport.hello()
  #expect(hello == DeviceHello(hubID: hubID, v: 1))
  #expect(await transport.matchesHub(hubID: hubID) == true)
  #expect(await transport.matchesHub(hubID: "aaaaaaaaaaaaaaaaaaaaaaaaaa") == false)

  let sealed = try DeviceEnvelope.makeRequest(
    op: "relay",
    body: [:],
    deviceID: "mac-abcd2345",
    hubPublicKey: hubKey.publicKey,
    senderPrivateKey: deviceKey
  )
  let reply = try await transport.send(sealed)
  #expect(reply.statusCode == 200)
  #expect(String(data: reply.body, encoding: .utf8) == #"{"v":1,"enc":"ok","ct":"ok"}"#)
}

/// 可选的真实中枢端到端测试：仅在外部脚本提供环境变量时运行，平时 `swift test` 自动跳过。
@Test func liveHubEndToEndWhenConfigured() async throws {
  let env = ProcessInfo.processInfo.environment
  guard let inviteURI = env["TACIT_SWIFT_E2E_INVITE"],
        let originString = env["TACIT_SWIFT_E2E_ORIGIN"] else {
    return
  }

  let invitation = try DevicePairingInvitation.parse(inviteURI)
  let originURL = try #require(URL(string: originString))
  let transport = try DirectDeviceTransport(origin: originURL)
  #expect(await transport.matchesHub(hubID: invitation.hubID) == true)

  let keyStore = InMemoryDeviceKeyStore()
  let client = DeviceClient(invitation: invitation, keyStore: keyStore, transport: transport)
  // 当前未改造的 hub/src/devices/service.ts 仅允许 platform = "android"（6.10 上线后放开 mac）。
  let paired = try await client.pair(invitation: invitation, deviceName: "Swift 端到端测试设备", platform: .android)
  #expect(paired.hubID == invitation.hubID)
  #expect(DeviceProtocol.isValidDeviceID(paired.deviceID))

  let relayReply = try await client.send(op: "relay")
  #expect(relayReply.status == 200)
  #expect(relayReply.body["relay"] == .null)

  struct SyncReply: Decodable, Equatable {
    let changes: [DeviceJSON]
    let cursor: Int
    let more: Bool
  }
  let syncReply = try await client.send(op: "sync", body: ["cursor": .int(0)], as: SyncReply.self)
  #expect(syncReply == SyncReply(changes: [], cursor: 0, more: false))

  // 如果外部脚本同时提供了管理接口信息，继续验证设备移除后的 401。
  if let adminBase = env["TACIT_SWIFT_E2E_ADMIN"], let token = env["TACIT_SWIFT_E2E_TOKEN"],
     let pairURL = URL(string: "\(adminBase)/v1/settings/devices/pairing"),
     let deleteURL = URL(string: "\(adminBase)/v1/settings/devices/\(paired.deviceID)") {
    var keepOpen = URLRequest(url: pairURL)
    keepOpen.httpMethod = "POST"
    keepOpen.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (_, pairResp) = try await URLSession.shared.data(for: keepOpen)
    #expect((pairResp as? HTTPURLResponse)?.statusCode == 200)

    var removeReq = URLRequest(url: deleteURL)
    removeReq.httpMethod = "DELETE"
    removeReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (_, delResp) = try await URLSession.shared.data(for: removeReq)
    #expect((delResp as? HTTPURLResponse)?.statusCode == 200)

    await #expect(throws: DeviceClientError.deviceRemoved(message: "设备未配对或已移除")) {
      _ = try await client.send(op: "sync", body: ["cursor": .int(0)])
    }
    #expect(await client.isRemoved == true)
  }
}
