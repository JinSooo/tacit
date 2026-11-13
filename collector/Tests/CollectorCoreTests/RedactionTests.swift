import Foundation
import Testing
@testable import CollectorCore

@Test func outboxRedactionMatchesSharedHubFixtures() throws {
  struct Example: Decodable { let input: String; let text: String; let count: Int }
  struct Fixture: Decodable { let strings: [Example]; let clipboard: [Example] }
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../schema/fixtures/redaction.json").standardizedFileURL
  let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  for e in fixture.strings {
    let r = RecordRedaction.string(e.input)
    #expect(r.text == e.text); #expect(r.count == e.count)
  }
  for e in fixture.clipboard {
    let record = Record(device: "test", source: "mac.clipboard", kind: "text", start: Date(), context: nil, title: e.input, body: e.input, capture: .init(method: "test"))
    let r = RecordRedaction.record(record)
    #expect(r.body == e.text); #expect(r.redactions == e.count)
  }
}
@Test func outboxRedactionCoversContextAndPreservesPrivate() {
  let fake = "ghp_" + String(repeating: "aB3", count: 12)
  var r = Record(device: "test", source: "mac.screen", kind: "text", start: Date(), context: .init(window: fake, extra: ["secret": .string(fake)]), title: fake, body: fake, capture: .init(method: "test"), people: [fake])
  r.sensitivity = "private"; r.redactions = 2
  let clean = RecordRedaction.record(r)
  #expect(clean.redactions == 7); #expect(clean.sensitivity == "private")
  #expect(clean.context?.extra?["secret"] == .string("[已脱敏:GitHub]"))
  #expect(r.body == fake)
}

@Test func outboxNeedsCompleteReceiptBeforeRemovingRecords() {
  func receipt(_ text: String) -> DeliveryReceipt? { DeliveryReceipt.decode(Data(text.utf8), batchCount: 2) }
  #expect(receipt(#"{"accepted":1,"duplicates":0,"rejected":[{"index":1,"errors":["invalid"]}]}"#)?.rejected.count == 1)
  #expect(receipt(#"{"accepted":0,"duplicates":2,"rejected":[]}"#)?.duplicates == 2)
  for bad in [#"{}"#, #"{"accepted":1,"duplicates":0,"rejected":[]}"#,
              #"{"accepted":true,"duplicates":1,"rejected":[]}"#,
              #"{"accepted":0,"duplicates":0,"rejected":[{"index":1,"errors":["invalid"]},{"index":1,"errors":["invalid"]}]}"#,
              #"{"accepted":1,"duplicates":0,"rejected":[{"index":2,"errors":["invalid"]}]}"#,
              #"{"accepted":1,"duplicates":0,"rejected":[{"index":1,"errors":[]}]}"#] {
    #expect(receipt(bad) == nil)
  }
}

@Test func outboxReceiptMatchesRealHubHTTPFixture() throws {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../schema/fixtures/ingest-receipt.json").standardizedFileURL
  let receipt = try #require(DeliveryReceipt.decode(Data(contentsOf: url), batchCount: 3))
  #expect(receipt.accepted == 1); #expect(receipt.duplicates == 1)
  #expect(receipt.rejected.map(\.index) == [2])
}
