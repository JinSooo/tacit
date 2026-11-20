import Foundation

public enum DailyTokenLimit {
  private static let tokensPerUnit = 10_000

  public static func inputText(tokens: Int) -> String {
    NSDecimalNumber(decimal: Decimal(tokens) / Decimal(tokensPerUnit)).stringValue
  }

  public static func tokens(from text: String, range: ClosedRange<Int>) -> Int? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let locale = Locale(identifier: "en_US_POSIX")
    guard text.range(of: #"\A[0-9]+(?:\.[0-9]{1,4})?\z"#, options: .regularExpression) != nil,
          let units = Decimal(string: text, locale: locale) else { return nil }
    let tokens = units * Decimal(tokensPerUnit)
    guard tokens >= Decimal(range.lowerBound), tokens <= Decimal(range.upperBound) else { return nil }
    return NSDecimalNumber(decimal: tokens).intValue
  }
}

public struct ModelUsageSummary: Decodable, Equatable {
  public let daysWithUsage: Int
  public let averageDailyTokens: Double?
  public let averageDailyTimelineTokens: Double?
  public let todayTokens: Int

  public var line: String? {
    guard daysWithUsage > 0, let averageDailyTokens, let averageDailyTimelineTokens else { return nil }
    func units(_ tokens: Double) -> String {
      (tokens / 10_000).formatted(.number.precision(.fractionLength(0...4)))
    }
    return "最近 7 天平均每天约 \(units(averageDailyTokens)) 万 token，其中时间线约 \(units(averageDailyTimelineTokens)) 万；今天已用 \(units(Double(todayTokens))) 万"
  }
}
