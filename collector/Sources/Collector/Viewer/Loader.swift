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

extension Loader where T: Equatable {
  /// 定时刷新时内容常常没变；原样赋值也会让页面整页重绘，所以只在值变化时替换。
  func run(_ load: () async throws -> T) async {
    loading = true; defer { loading = false }
    do {
      let next = try await load()
      if value != next { value = next }
      if error != nil { error = nil }
    }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }
}
