import Foundation
import Darwin

/// launchd 的 SIGTERM 交回主队列，复用 AppKit 的正常退出收尾。
public final class TerminationSignal {
  private let source: DispatchSourceSignal
  public init(queue: DispatchQueue = .main, handler: @escaping () -> Void) {
    signal(SIGTERM, SIG_IGN)
    source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    source.setEventHandler(handler: handler)
    source.resume()
  }
  deinit { source.cancel() }
}
