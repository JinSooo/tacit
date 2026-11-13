import Foundation
import Testing
@testable import CollectorCore

@Test func speakerConsolidationUsesSharedContractVectors() throws {
  struct Speaker: Decodable { let local: String; let seconds: Double; let centroid: [Float] }
  struct Sample: Decodable { let name: String; let speakers: [Speaker]; let groups: [[String]] }
  let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../schema/fixtures/speaker-consolidation.json").standardizedFileURL
  let cases = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: file))
  for sample in cases {
    let speakers = sample.speakers.map { s in LocalSpeaker(local:s.local,track:.mic,seconds:s.seconds,centroid:s.centroid,weightedSum:s.centroid.map {Double($0)*s.seconds}) }
    let mapping = WorkerLogic.consolidate(speakers)
    let groups = Dictionary(grouping: speakers.map(\.local), by: { mapping[$0] ?? $0 }).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    #expect(groups == sample.groups, "共享用例：\(sample.name)")
  }
}
