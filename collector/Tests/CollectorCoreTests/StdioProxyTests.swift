import CollectorCore
import CryptoKit
import Foundation
import Testing

@Suite struct StdioProxyTests {
  @Test func audioPathTranslationAndSanitization() throws {
    let (syncOp, syncBody) = try AudioProxy.translateHTTPPath("/v1/audio/sync?device=mac", body: nil)
    #expect(syncOp == "audio.sync")
    #expect(syncBody.isEmpty)

    let (skipOp, skipBody) = try AudioProxy.translateHTTPPath("/v1/audio/conversations/conv%2042/skipped", body: Data("{}".utf8))
    #expect(skipOp == "audio.skipped")
    #expect(skipBody["conversation_ref"] == .string("conv 42"))

    let embData = Data(#"{"device":"mac","conversation_ref":"c1","t_start":"2026-11-23T10:00:00Z","t_end":"2026-11-23T10:01:00Z","speakers":[]}"#.utf8)
    let (embOp, embBody) = try AudioProxy.translateHTTPPath("/v1/audio/embeddings", body: embData)
    #expect(embOp == "audio.embeddings")
    #expect(embBody["device"] == nil)
    #expect(embBody["conversation_ref"] == .string("c1"))

    #expect(throws: StdioChannelError.unsupportedOp) {
      _ = try AudioProxy.translateHTTPPath("/v1/settings/models", body: nil)
    }

    // 宿主侧白名单阻止越权 op 及非 mac.audio 来源。
    #expect(throws: StdioChannelError.unsupportedOp) {
      _ = try AudioProxy.sanitizeBody(op: "delete", body: ["ids": .array([])], deviceID: "mac-abcd2345")
    }
    #expect(throws: StdioChannelError.invalidSource) {
      _ = try AudioProxy.sanitizeBody(
        op: "ingest",
        body: ["records": .array([.object(["source": .string("mac.screen"), "device": .string("mac")])])],
        deviceID: "mac-abcd2345"
      )
    }
    let stamped = try AudioProxy.sanitizeBody(
      op: "ingest",
      body: ["device": .string("mac"), "records": .array([.object(["source": .string("mac.audio"), "device": .string("mac")])])],
      deviceID: "mac-abcd2345"
    )
    #expect(stamped["device"] == nil)
    #expect(stamped["records"]?.arrayValue?.first?["device"] == .string("mac-abcd2345"))
  }

  @Test func pluginProxyForwardsBatchesValidatesReceiptAndPreservesSummary() async throws {
    let childToHost = Pipe()
    let hostToChild = Pipe()
    let hostChannel = StdioLineChannel(
      readFD: childToHost.fileHandleForReading.fileDescriptor,
      writeFD: hostToChild.fileHandleForWriting.fileDescriptor
    )
    let childChannel = StdioLineChannel(
      readFD: hostToChild.fileHandleForReading.fileDescriptor,
      writeFD: childToHost.fileHandleForWriting.fileDescriptor
    )

    var seenDevices: [String] = []
    var calls = 0
    let serverTask = Task {
      await PluginProxy.serve(
        channel: hostChannel,
        deviceID: "mac-abcd2345",
        allowedSources: PluginProxy.allowedSources(for: "ext-demo")
      ) { op, body in
        #expect(op == "ingest")
        calls += 1
        let records = try #require(body["records"]?.arrayValue)
        seenDevices.append(contentsOf: records.compactMap { $0["device"]?.stringValue })
        let receipt = Data(#"{"accepted":1,"duplicates":0,"rejected":[]}"#.utf8)
        let decoded = try JSONDecoder().decode([String: DeviceJSON].self, from: receipt)
        return DeviceResponsePayload(status: 200, body: decoded, bodyData: receipt)
      }
    }

    let encoder = AudioProxy.jsonEncoder()
    let decoder = JSONDecoder()

    // 1. 合法批次：device 被覆盖为 mac-abcd2345，收到回执。
    let okReq = PluginIngestRequest(id: 1, records: [
      .object(["id": .string("01TEST"), "source": .string("plugin.ext_demo"), "device": .string("mac")]),
    ])
    try childChannel.writeLine(encoder.encode(okReq))
    let reply1Data = try #require(try childChannel.readLine())
    let reply1 = try decoder.decode(PluginIngestResponse.self, from: reply1Data)
    #expect(reply1.ok == true && reply1.id == 1 && reply1.result?["accepted"] == .int(1))

    // 2. 越权来源：宿主拦截并返回 403，不调用 send。
    let badReq = PluginIngestRequest(id: 2, records: [
      .object(["id": .string("02TEST"), "source": .string("manual.correction"), "device": .string("mac")]),
    ])
    try childChannel.writeLine(encoder.encode(badReq))
    let reply2Data = try #require(try childChannel.readLine())
    let reply2 = try decoder.decode(PluginIngestResponse.self, from: reply2Data)
    #expect(reply2.ok == false && reply2.id == 2 && reply2.status == 403 && reply2.error == "invalid_source")

    // 3. 最后输出摘要行并关闭写端。
    try childChannel.writeLine(Data(#"{"accepted":1,"duplicates":0,"rejected":0,"exitCode":0}"#.utf8))
    try childToHost.fileHandleForWriting.close()

    let summary = await serverTask.value
    try? childToHost.fileHandleForReading.close()
    try? hostToChild.fileHandleForReading.close()
    try? hostToChild.fileHandleForWriting.close()

    #expect(calls == 1)
    #expect(seenDevices == ["mac-abcd2345"])
    #expect(summary.contains(#""accepted":1"#))
  }

  @Test func collectorStatusReportEncodingAndThrottle() throws {
    let encoder = JSONEncoder()
    let disabledReport = CollectorStatusReport(
      time: "2026-11-23T19:30:00+09:00",
      transcription: nil,
      outbox: OutboxStatus(bytes: 256, dropped: 0, degraded: false),
      hubBusy: 1,
      queuePeak: 4
    )
    let raw = try encoder.encode(disabledReport)
    let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    #expect(json["transcription"] is NSNull)
    #expect((json["outbox_bytes"] as? NSNumber)?.int64Value == 256)
    #expect((json["hub_busy"] as? NSNumber)?.intValue == 1)
    #expect((json["queue_peak"] as? NSNumber)?.intValue == 4)

    var throttle = CollectorStatusThrottle(interval: 60, errorCooldown: 5)
    // 首次立即上报。
    #expect(throttle.shouldSend(disabledReport, hasError: false, now: 100))
    throttle.recordSent(disabledReport, hasError: false, at: 100)
    // 未到 60 秒且无新错误不上报。
    #expect(!throttle.shouldSend(disabledReport, hasError: false, now: 130))
    // 满 60 秒定期上报。
    #expect(throttle.shouldSend(disabledReport, hasError: false, now: 160))
    // 出现错误：冷却期（<5s）内抑制，超过 5s 立即上报。
    let degraded = CollectorStatusReport(
      time: "2026-11-23T19:30:03+09:00",
      transcription: TranscriptionStatus(pending: 2, failed: 1),
      outbox: OutboxStatus(bytes: 512, dropped: 1, degraded: true),
      hubBusy: 2,
      queuePeak: 8
    )
    #expect(!throttle.shouldSend(degraded, hasError: true, now: 103))
    #expect(throttle.shouldSend(degraded, hasError: true, now: 106))
    throttle.recordSent(degraded, hasError: true, at: 106)
    // 错误未继续加重时不重复触发。
    #expect(!throttle.shouldSend(degraded, hasError: true, now: 120))
    // force 始终允许上报。
    #expect(throttle.shouldSend(degraded, hasError: true, force: true, now: 107))
  }

  @Test func hostDeviceSessionHandlesMissingLinkAndDisable() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("host-session-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let files = LocalDeviceLink.Files(directory: dir)
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let hub = Curve25519.KeyAgreement.PrivateKey()
    let keys = LocalDeviceLink.Keys(read: { _ in mac.rawRepresentation }, create: { _, _ in })
    let session = HostDeviceSession(
      origin: { URL(string: "http://127.0.0.1:47823")! },
      files: files,
      keys: keys
    )

    // 没有 collector-link.json 时返回 nil，不抛错。
    #expect(await session.currentLink() == nil)
    #expect(try await session.send(op: "audio.sync") == nil)

    // 写入合法 collector-link.json 后可识别连接。
    let linkJSON = try JSONEncoder().encode([
      "hub_id": DeviceProtocol.hubID(for: hub.publicKey),
      "hub_pk": DeviceEnvelope.publicKeyBase64URL(hub.publicKey),
      "device_id": "mac-abcd2345",
      "mode": "local",
    ])
    var obj = try JSONSerialization.jsonObject(with: linkJSON) as! [String: Any]
    obj["addrs"] = ["http://127.0.0.1:47823"]
    obj["relay"] = NSNull()
    try files.write(.collector, JSONSerialization.data(withJSONObject: obj))

    #expect(await session.currentLink()?.device_id == "mac-abcd2345")
    #expect(try await session.connection()?.link.device_id == "mac-abcd2345")

    // handleDeviceRemoved 撤下连接文件并停用本轮设备协议。
    await session.handleDeviceRemoved()
    #expect(await session.currentLink() == nil)
    #expect(try files.collector() == nil)
  }
}
