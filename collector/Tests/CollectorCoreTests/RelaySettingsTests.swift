import Foundation
import Testing
@testable import CollectorCore

@Test(arguments: [
  "https://mailbox.example",
  "https://mailbox.example:8443/relay/",
  "HTTP://LOCALHOST:8000",
  "http://127.0.0.1:8000/relay",
])
func acceptsRelayAddresses(_ address: String) {
  #expect(RelaySettingsText.validatedAddress("  \(address)\n") == address)
}

@Test(arguments: [
  "", "mailbox.example", "https:///relay", "ftp://mailbox.example",
  "http://mailbox.example", "http://192.0.2.1", "http://localhost.example",
  "https://user:pass@mailbox.example", "https://@mailbox.example", "https://mailbox.example?code=sample",
  "https://mailbox.example#", "https://mailbox.example:70000", "https://mailbox.example/a b",
  "https://mailbox.example\\relay",
])
func rejectsInvalidRelayAddresses(_ address: String) {
  #expect(RelaySettingsText.validatedAddress(address) == nil)
}

@Test func presentsConnectedRelayWithPendingMessagesAndRetirement() throws {
  let settings = try decodeRelay("""
    {
      "mode":"custom","url":"https://relay.example","connected":true,
      "last_fetch_at":"2026-11-23T08:15:00.000Z","used_bytes":233,"unprocessable":0,
      "devices":[{"device":"phone-a","pending":2},{"device":"phone-b","pending":3},
                 {"device":"phone-c","pending":null},{"device":"phone-d","pending":0}],
      "retiring":[{"url":"https://old.relay.example","retire_at":"2026-11-29T16:00:00.000Z"},
                  {"url":"https://older.relay.example","retire_at":"2026-11-28T16:00:00.000Z"}]
    }
    """)
  #expect(RelaySettingsText.connection(settings, calendar: testCalendar) == nil)
  #expect(RelaySettingsText.lastFetch(settings, calendar: testCalendar) == "11 月 23 日 17:15")
  #expect(RelaySettingsText.pending(settings) == "5 条")
  #expect(RelaySettingsText.retirement(settings, calendar: testCalendar) == "旧信箱保留到 11 月 30 日")
}

@Test func presentsDisconnectedRelayWithoutEmptyDetails() throws {
  let settings = try decodeRelay("""
    {
      "mode":"custom","url":"https://relay.example","connected":false,
      "last_fetch_at":"2026-11-23T08:15:00.000Z","used_bytes":null,"unprocessable":0,
      "devices":[{"device":"phone-a","pending":null},{"device":"phone-b","pending":0}],"retiring":[]
    }
    """)
  #expect(RelaySettingsText.connection(settings) == "连不上信箱，请检查地址和网络。")
  #expect(RelaySettingsText.pending(settings) == nil)
  #expect(RelaySettingsText.retirement(settings) == nil)
}

@Test func presentsConnectedRelayBeforeFirstFetch() throws {
  let settings = try decodeRelay("""
    {
      "mode":"custom","url":"https://relay.example","connected":true,"last_fetch_at":null,
      "used_bytes":null,"unprocessable":0,"devices":[],"retiring":[]
    }
    """)
  #expect(RelaySettingsText.connection(settings) == nil)
  #expect(RelaySettingsText.lastFetch(settings) == nil)
}

@Test func presentsRelayLastFetchAsLocalDateAndTime() throws {
  let settings = try decodeRelay("""
    {
      "mode":"custom","url":"https://relay.example","connected":false,
      "last_fetch_at":"2026-11-25T05:30:00.000Z",
      "used_bytes":null,"unprocessable":0,"devices":[],"retiring":[]
    }
    """)
  #expect(RelaySettingsText.lastFetch(settings, calendar: testCalendar) == "11 月 25 日 14:30")
}

@Test func presentsOnlyRetirementAfterDisablingRelay() throws {
  let settings = try decodeRelay("""
    {
      "mode":"off","url":null,"connected":false,"last_fetch_at":null,"used_bytes":null,
      "unprocessable":0,"devices":[],
      "retiring":[{"url":"https://old.relay.example","retire_at":"2026-11-29T16:00:00.000Z"}]
    }
    """)
  #expect(RelaySettingsText.connection(settings) == nil)
  #expect(RelaySettingsText.pending(settings) == nil)
  #expect(RelaySettingsText.retirement(settings, calendar: testCalendar) == "旧信箱保留到 11 月 30 日")
}

@Test(arguments: [
  (0, "暂时无法与后台服务通信，请稍后再试。"),
  (400, "地址无效，或该地址没有 Tacit 信箱。"),
  (403, "开通码不正确，请检查后再试。"),
  (429, "信箱请求次数已达今天的上限，请明天再试。"),
  (502, "连不上信箱，请检查地址和网络。"),
  (503, "后台服务正忙，请稍后再试。"),
  (507, "信箱空间已满，请腾出空间后再试。"),
  (500, "信箱操作失败，请稍后再试。"),
])
func presentsRelayFailures(_ status: Int, _ message: String) {
  #expect(RelaySettingsText.failure(status: status) == message)
}

private func decodeRelay(_ json: String) throws -> RelaySettings {
  try HubJSON.decoder().decode(RelaySettings.self, from: Data(json.utf8))
}

private var testCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
  return calendar
}

// 2026-11-24：后台显示自己今天对信箱的请求次数，被限流后说明已到上限；旧版后台不带这一项时不显示。
@Test func presentsTodaysRelayUsageAndLimit() throws {
  let base = """
    "mode":"custom","url":"https://relay.example","connected":true,"last_fetch_at":null,
    "used_bytes":0,"unprocessable":0,"devices":[],"retiring":[]
    """
  let normal = try decodeRelay("""
    {\(base),"usage":{"day":"2026-11-24","requests":12345,"by_kind":{"poll":12000,"push":345},
     "limited_at":null,"requests_before_limit":null}}
    """)
  #expect(normal.usage?.byKind["poll"] == 12000)
  #expect(RelaySettingsText.usage(normal)?.text == "12,345 次")
  #expect(RelaySettingsText.usage(normal)?.limited == false)
  let limited = try decodeRelay("""
    {\(base),"usage":{"day":"2026-11-24","requests":9000,"by_kind":{"poll":9000},
     "limited_at":"2026-11-24T11:02:00.000Z","requests_before_limit":8999}}
    """)
  #expect(RelaySettingsText.usage(limited)?.text == "9,000 次，已到信箱今天的上限")
  #expect(RelaySettingsText.usage(limited)?.limited == true)
  #expect(RelaySettingsText.usage(try decodeRelay("{\(base)}")) == nil)
}

// 2026-11-24：信箱限流时状态行写“连不上信箱，请检查地址和网络”，让人白查地址；改为说明限流和再试时刻。
@Test(ChineseUITrait()) func limitedRelayExplainsPauseInsteadOfNetwork() throws {
  let base = """
    "mode":"custom","url":"https://relay.example","last_fetch_at":null,
    "used_bytes":0,"unprocessable":0,"devices":[],"retiring":[]
    """
  var shanghai = Calendar(identifier: .gregorian); shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  let now = ISO8601DateFormatter().date(from: "2026-11-24T14:20:00Z")!  // 北京时间 22:20
  let paused = try decodeRelay("{\(base),\"connected\":true,\"paused_until\":\"2026-11-24T14:52:00.000Z\"}")
  #expect(RelaySettingsText.connection(paused, now: now, calendar: shanghai) == "信箱暂时限流，22:52 再试。")
  let overnight = try decodeRelay("{\(base),\"connected\":true,\"paused_until\":\"2026-11-24T16:30:00.000Z\"}")
  #expect(RelaySettingsText.connection(overnight, now: now, calendar: shanghai) == "信箱暂时限流，明天 00:30 再试。")
  // 暂停已过、真的连不上时仍提示检查地址和网络。
  let offline = try decodeRelay("{\(base),\"connected\":false,\"paused_until\":\"2026-11-24T14:00:00.000Z\"}")
  #expect(RelaySettingsText.connection(offline, now: now, calendar: shanghai) == "连不上信箱，请检查地址和网络。")
}
