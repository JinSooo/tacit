import AppKit
import CollectorCore
import SwiftUI
import Testing
@testable import Collector

private func device(_ id: String, _ name: String, _ platform: String, _ role: DeviceSettings.Role) -> DeviceSettings.Device {
  .init(id: id, name: name, platform: platform, pairedAt: "2026-11-23T08:00:00Z",
        lastSeen: LocalTime.iso(Date.now.addingTimeInterval(-300)), records: 0, pendingChanges: 0, role: role)
}

private func fixture() -> DeviceSettings {
  .init(hubId: nil, lan: .init(open: false, port: 47824, addrs: []), pairing: nil, devices: [
    device("android-demo", "随身手机", "android", .collect),
    device("mac-studio", "书房的 Mac", "mac", .view),
    device("agent-demo", "Tacit AI", "agent", .agent),
    device("mac-local", "我的 Mac", "mac", .admin),
  ], currentDeviceId: "mac-local")
}

@Test func deviceListMovesCurrentMacFirstAndOmitsAgent() {
  let settings = fixture()
  #expect(settings.displayedDevices.map(\.id) == ["mac-local", "android-demo", "mac-studio"])
}

@Test func deviceActionsFollowPlatformAndRoleAndProtectCurrentMac() {
  let cases: [(String, DeviceSettings.Role, [DeviceSettings.Role], Bool)] = [
    ("mac", .admin, [.view, .collect], true),
    ("mac", .view, [.collect], true),
    ("mac", .collect, [.view], true),
    ("mac", .agent, [], false),
    ("android", .collect, [.view], true),
    ("android", .view, [.collect], true),
    ("android", .admin, [], true),
    ("android", .agent, [], false),
    ("agent", .agent, [], false),
  ]
  for (platform, role, expected, removable) in cases {
    let row = device("device-fixture", "合成设备", platform, role)
    #expect(row.offeredRoles(isCurrent: false) == expected)
    #expect(row.canRemove(isCurrent: false) == removable)
    #expect(row.offeredRoles(isCurrent: true).isEmpty)
    #expect(!row.canRemove(isCurrent: true))
  }
}

@Test func deviceActionsPreserveHubConflictAndForbiddenMessages() async {
  let messages = ["devices.remove": HubError(message: "不能移除最后一台管理设备", status: 409),
                  "devices.role.update": HubError(message: "手机只能使用采集权限", status: 403)]
  let api = HubAPI(base: { URL(string: "http://unused.test")! }, token: { nil }, deviceAction: { op, _, _, _ in
    let reply = try #require(messages[op])
    throw AdaptiveViewerDataSource.mapDeviceError(.operationError(op: op, status: reply.status, message: reply.message))
  })
  let actions: [(HubError, () async throws -> Void)] = [
    (messages["devices.remove"]!, { try await api.removeDevice("mac-fixture") }),
    (messages["devices.role.update"]!, { try await api.updateDeviceRole("mac-fixture", role: "view") }),
  ]
  for (expected, action) in actions {
    do {
      try await action()
      Issue.record("应保留后台服务的操作错误")
    } catch {
      #expect((error as? HubError)?.status == expected.status)
      #expect((error as? HubError)?.actionMessage == expected.message)
    }
  }
}

@MainActor @Test func acknowledgingTimelineSecurityEventRemovesIt() async throws {
  let event = TimelineSecurityEvent(id: "fixture-event", action: .modelKeyChange)
  let api = HubAPI(base: { URL(string: "http://unused.test")! }, token: { nil }, deviceAction: { op, fields, _, _ in
    switch op {
    case "settings.security-events.list":
      let body: [String: DeviceJSON] = ["events": .array([.object(["id": .string(event.id), "action": .string("key.set")])])]
      return try .init(status: 200, body: body, bodyData: JSONEncoder().encode(body))
    case "settings.security-events.ack":
      #expect(fields == ["id": .string(event.id)])
      return .init(status: 200, body: [:], bodyData: Data())
    default:
      Issue.record("意外的设备操作")
      throw CancellationError()
    }
  })
  let state = TimelineSecurityEventState()
  await state.refresh(using: api)
  #expect(state.events.map(\.message) == ["另一台设备修改了 AI 模型的密钥"])
  await state.acknowledge(event, using: api)
  #expect(state.events.isEmpty)
}

@MainActor @Test func renderDeviceSettingsSnapshots() throws {
  let output = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/ui-snapshots")
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

  for scheme: ColorScheme in [.light, .dark] {
    let variant = scheme == .light ? "light" : "dark"
    func render(_ name: String, _ content: some View) throws {
      let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
      renderer.scale = 2
      let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
      var image: CGImage?
      appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
      let bitmap = NSBitmapImageRep(cgImage: try #require(image))
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: output.appendingPathComponent("\(name)-\(variant).png"))
    }

    func settingsList(expanded: Bool) -> some View {
      let settings = fixture()
      return VStack(alignment: .leading, spacing: 10) {
        Text("设备").font(.system(size: TextSize.title, weight: .semibold))
        VStack(spacing: 8) {
          ForEach(settings.displayedDevices) { row in
            DeviceSettingsRow(device: row, isCurrent: row.id == settings.currentDeviceId,
                              expanded: expanded && row.id == "mac-studio", toggle: {}, changeRole: { _ in }, remove: {})
            Divider()
          }
          Button("添加设备") {}.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).card()
      }
      .font(.system(size: TextSize.body))
      .padding(20).frame(width: 520)
      .background(Palette.paper)
      .tint(Palette.accent)
    }

    func invitation(_ step: DeviceInvitationChoices.Step) -> some View {
      DeviceInvitationChoices(step: step, busy: false, error: nil, selectMac: {},
                              invite: { _, _ in }, cancel: {}, back: {})
        .background(Palette.paperRaised)
    }

    try render("device-list", settingsList(expanded: false))
    try render("device-actions", settingsList(expanded: true))
    try render("add-device", invitation(.type))
    try render("confirm-admin", invitation(.confirmAdmin))
    try render("security-event", TimelineSecurityEventLine(
      event: .init(id: "fixture-event", action: .modelKeyChange), acknowledge: {}
    ).padding(20).frame(width: 620).background(Palette.paper))
  }
}

@Test(arguments: [(-5, "剩余 0 秒"), (45, "剩余 45 秒"), (60, "剩余 1 分钟"), (300, "剩余 5 分钟"), (305, "剩余 5 分 5 秒")])
func deviceInvitationCountdown(_ seconds: Int, _ expected: String) {
  #expect(DeviceInvitationChoices.countdown(seconds) == expected)
}
