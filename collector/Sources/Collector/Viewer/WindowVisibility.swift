import AppKit

/// 主窗口关掉、最小化、被完全遮住、锁屏或显示器睡眠时，各页面的定时刷新暂停；窗口重新露出来后立即补上一轮。
/// 关掉的窗口不会释放，里面的页面任务仍在跑，不暂停的话打开过一次窗口就会一直每分钟重读全天记录。
@MainActor enum WindowVisibility {
  private(set) static var visible = false
  private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// 正在等满间隔的刷新循环；窗口重新露出时提前叫醒，不用等剩下的间隔。
  private static var sleepers: [UUID: CheckedContinuation<Void, Never>] = [:]
  static var onChange: ((Bool) -> Void)?

  static func update(_ window: NSWindow) {
    let next = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    let changed = next != visible
    visible = next
    if changed { onChange?(next) }
    if changed, visible, !sleepers.isEmpty {
      let early = sleepers.values; sleepers = [:]
      early.forEach { $0.resume() }
    }
    guard visible, !waiters.isEmpty else { return }
    let ready = waiters.values; waiters = [:]
    ready.forEach { $0.resume() }
  }

  /// 代替页面刷新循环里的 `Task.sleep`：等满间隔（窗口从看不见变回看得见时提前结束），窗口不可见时挂起到可见或任务取消，期间不唤醒。
  static func pause(_ interval: Duration) async {
    let sleeper = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume(); return }
        sleepers[sleeper] = continuation
        Task { @MainActor in
          try? await Task.sleep(for: interval)
          sleepers.removeValue(forKey: sleeper)?.resume()
        }
      }
    } onCancel: {
      Task { @MainActor in sleepers.removeValue(forKey: sleeper)?.resume() }
    }
    guard !visible, !Task.isCancelled else { return }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if visible || Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
      }
    } onCancel: {
      Task { @MainActor in waiters.removeValue(forKey: id)?.resume() }
    }
  }
}
