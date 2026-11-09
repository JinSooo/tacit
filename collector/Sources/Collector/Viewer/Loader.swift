import Foundation
import Observation

/// 读取一次、可重试的资源状态。
@MainActor @Observable final class Loader<T> {
  var value: T?
  var error: String?
  var loading = false
  func run(_ load: () async throws -> T) async {
    loading = true; defer { loading = false }
    do { value = try await load(); error = nil }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }
}
