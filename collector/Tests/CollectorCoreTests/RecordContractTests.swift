import Foundation
import Testing
@testable import CollectorCore

@Test func macWireRecordRoundTripsSharedSchemaFixtureWithoutDroppingFields() throws {
  let file = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("../../../schema/fixtures/mac-record.json").standardizedFileURL
  let data = try Data(contentsOf:file)
  let record = try JSONDecoder().decode(Record.self,from:data)
  let output = try JSONEncoder().encode(record)
  let original = try JSONSerialization.jsonObject(with:data) as! NSDictionary
  let encoded = try JSONSerialization.jsonObject(with:output) as! NSDictionary
  #expect(original == encoded)
}
