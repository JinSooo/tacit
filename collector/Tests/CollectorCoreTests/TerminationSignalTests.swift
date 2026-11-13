import XCTest
import Darwin
@testable import CollectorCore

final class TerminationSignalTests: XCTestCase {
  func testSIGTERMRunsCleanup() {
    let called = expectation(description: "SIGTERM cleanup")
    let watcher = TerminationSignal(queue: DispatchQueue(label: "test.termination")) { called.fulfill() }
    kill(getpid(), SIGTERM)
    wait(for: [called], timeout: 2)
    withExtendedLifetime(watcher) {}
  }
}
