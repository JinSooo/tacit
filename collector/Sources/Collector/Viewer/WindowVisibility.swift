import AppKit

/// 主窗口关掉、最小化、被完全遮住、锁屏或显示器睡眠时，各页面的定时刷新暂停；窗口重新露出来后立即补上一轮。
/// 关掉的窗口不会释放，里面的页面任务仍在跑，不暂停的话打开过一次窗口就会一直每分钟重读全天记录。
@MainActor enum WindowVisibility {
  private(set) static var visible = false
  private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  static func update(_ window: NSWindow) {
    visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    guard visible, !waiters.isEmpty else { return }
    let ready = waiters.values; waiters = [:]
    ready.forEach { $0.resume() }
  }

  /// 代替页面刷新循环里的 `Task.sleep`：先等满间隔，窗口不可见时挂起到可见或任务取消，期间不唤醒。
  static func pause(_ interval: Duration) async {
    try? await Task.sleep(for: interval)
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
