import Foundation
import Testing
@testable import CollectorCore

@Test func slowMaintenanceDoesNotBlockCaptureAndDoesNotQueueDuplicates() {
  let state = DispatchQueue(label: "synthetic-audio-state"), maintenance = BackgroundMaintenance()
  let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), callback = DispatchSemaphore(value: 0)
  let began = Date()
  let accepted = maintenance.perform(returningTo: state, operation: { started.signal(); _ = release.wait(timeout: .now()+2); return 7 }, completion: { result in
    #expect((try? result.get()) == 7); #expect(!maintenance.isRunning); callback.signal()
  })
  #expect(accepted)
  #expect(started.wait(timeout: .now()+1) == .success)
  var captureRan = false
  state.sync { captureRan = true }
  #expect(captureRan); #expect(Date().timeIntervalSince(began) < 1)
  #expect(!maintenance.perform(returningTo: state, operation: { 8 }, completion: { _ in Issue.record("不能叠加扫描") }))
  release.signal(); maintenance.drain()
  #expect(callback.wait(timeout: .now()+1) == .success)
}
