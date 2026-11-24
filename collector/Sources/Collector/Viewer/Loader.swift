import Foundation
import Observation
import SwiftUI

/// 读取一次、可重试的资源状态。
@MainActor @Observable final class Loader<T> {
  var value: T?
  var error: String?
  var loading = false
  /// 读到新内容时用 Motion.standard 换上去：加载 → 内容交叉淡入，新增的行顺滑让位。
  @ObservationIgnored let animated: Bool

  init(animated: Bool = false) { self.animated = animated }

  func run(_ load: () async throws -> T) async {
    loading = true; defer { loading = false }
    do {
      let next = try await load()
      apply { value = next; error = nil }
    }
    catch is CancellationError {}
    catch { let message = error.localizedDescription; apply { self.error = message } }
  }

  func apply(_ change: () -> Void) {
    if animated { withAnimation(Motion.standard, change) } else { change() }
  }
}

extension Loader where T: Equatable {
  /// 定时刷新时内容常常没变；原样赋值也会让页面整页重绘，所以只在值变化时替换。
  func run(_ load: () async throws -> T) async {
    loading = true; defer { loading = false }
    do {
      let next = try await load()
      guard value != next || error != nil else { return }
      apply {
        if value != next { value = next }
        if error != nil { error = nil }
      }
    }
    catch is CancellationError {}
    catch { let message = error.localizedDescription; apply { self.error = message } }
  }
}
