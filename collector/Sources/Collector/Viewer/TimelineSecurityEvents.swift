import SwiftUI
import Observation

struct TimelineSecurityEvent: Decodable, Identifiable {
  enum Action: String, Decodable {
    case managementPairing = "pair.complete"
    case roleChange = "device.role_change"
    case modelKeyChange = "key.set"
  }

  let id: String
  let action: Action

  var message: String {
    switch action {
    case .managementPairing: "有一台新的管理设备已连接"
    case .roleChange: "另一台设备修改了设备权限"
    case .modelKeyChange: "另一台设备修改了 AI 模型的密钥"
    }
  }
}

@MainActor @Observable final class TimelineSecurityEventState {
  private(set) var events: [TimelineSecurityEvent] = []
  private(set) var acknowledging = false
  private(set) var error: String?
  private var revision = 0

  func refresh(using api: HubAPI) async {
    guard !acknowledging else { return }
    let requestRevision = revision
    do {
      let pending = try await api.pendingSecurityEvents()
      guard !Task.isCancelled, requestRevision == revision else { return }
      events = pending
    } catch let problem as HubError where problem.status == 403 || problem.status == 404 {
      guard !Task.isCancelled, requestRevision == revision else { return }
      events = []
      error = nil
    } catch {
      // Keep the current prompt if the connection is briefly unavailable.
    }
  }

  func acknowledge(_ event: TimelineSecurityEvent, using api: HubAPI) async {
    guard !acknowledging else { return }
    acknowledging = true
    revision += 1
    error = nil
    defer { acknowledging = false }
    do {
      try await api.acknowledgeSecurityEvent(event.id)
      events.removeAll { $0.id == event.id }
    } catch let problem as HubError where problem.status == 404 {
      // The audit retention window may have expired since the line was shown.
      events.removeAll { $0.id == event.id }
    } catch {
      self.error = (error as? HubError)?.actionMessage ?? "暂时无法确认，请重试。"
    }
  }
}

struct TimelineSecurityEventLine: View {
  let event: TimelineSecurityEvent
  let acknowledge: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.shield").frame(width: 14).accessibilityHidden(true)
      Text(event.message)
      Spacer(minLength: 8)
      Button("知道了", action: acknowledge).buttonStyle(.accentLink).fixedSize()
    }
    .font(.system(size: TextSize.body))
    .foregroundStyle(Palette.accent)
    .padding(.vertical, 4)
  }
}
