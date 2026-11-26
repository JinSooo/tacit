import Foundation
import Testing
@testable import Collector

// Sparkle 拿本机的 CFBundleVersion（提交号）和 appcast 里的短版本号比；不换算的话提交号和版本号比不出新旧。
@Test func updaterComparesShortVersionsInsteadOfCommitHashes() {
  let comparator = ShortVersionComparator(build: "35abc75", short: "0.7.4")
  #expect(comparator.compareVersion("35abc75", toVersion: "0.7.5") == .orderedAscending)
  #expect(comparator.compareVersion("35abc75", toVersion: "0.7.4") == .orderedSame)
  #expect(comparator.compareVersion("35abc75", toVersion: "0.7.3") == .orderedDescending)
  #expect(comparator.compareVersion("0.7.10", toVersion: "35abc75") == .orderedDescending)
}
