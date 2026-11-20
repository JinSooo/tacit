import Foundation
import XCTest
@testable import CollectorCore

final class ModelUsageTests: XCTestCase {
  func testLimitConvertsTenThousandsToExactIntegerTokens() {
    let range = 1...1_000_000_000
    for (value, text) in [(1, "0.0001"), (12_345, "1.2345"), (40_000, "4"), (1_000_000_000, "100000")] {
      XCTAssertEqual(DailyTokenLimit.inputText(tokens: value), text)
      XCTAssertEqual(DailyTokenLimit.tokens(from: text, range: range), value)
    }
    for invalid in ["", "0", "-1", "1e2", "0.00001", "100000.0001", "1.2token"] {
      XCTAssertNil(DailyTokenLimit.tokens(from: invalid, range: range))
    }
  }

  func testLineRequiresReportedUsageAndIncludesZeroTimelineUsage() throws {
    let decoder = HubJSON.decoder()
    let empty = try decoder.decode(ModelUsageSummary.self, from: Data(
      #"{"days_with_usage":0,"average_daily_tokens":null,"average_daily_timeline_tokens":null,"today_tokens":0}"#.utf8
    ))
    XCTAssertNil(empty.line)
    let reported = try decoder.decode(ModelUsageSummary.self, from: Data(
      #"{"days_with_usage":2,"average_daily_tokens":40000,"average_daily_timeline_tokens":0,"today_tokens":10000}"#.utf8
    ))
    XCTAssertEqual(reported.line, "最近 7 天平均每天约 4 万 token，其中时间线约 0 万；今天已用 1 万")
  }
}
