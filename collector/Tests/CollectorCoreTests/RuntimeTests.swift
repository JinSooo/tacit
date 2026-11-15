import Foundation
import Testing
@testable import CollectorCore

@Test func runtimeStatusDistinguishesReturnValidationAndUse() throws {
  func call(_ state: String) throws -> ModelCall {
    let text = #"{"id":"synthetic","at":"2026-11-13T12:00:00Z","task":"thread_digest","model":"synthetic","provider_state":"returned","validation_state":"passed","application_state":"\#(state)","content_state":"available","ms":1020}"#
    return try HubJSON.decoder().decode(ModelCall.self,from:Data(text.utf8))
  }
  #expect(try call("pending").status == "校验通过，待确认采用")
  #expect(try call("applied").status == "已用于更新")
  #expect(try call("unknown").status.contains("采用情况未记录"))
  #expect(try call("discarded").status.contains("未采用"))
  #expect(try call("applied").elapsed == "1.0 秒")
}

@Test func runtimeSnapshotRemovalsAndExactContextDecode() throws {
  let text = #"{"kind":"context","transport":null,"content_state":"available","request":{"text":"合成中文🙂\n第二行"},"response":null,"response_truncated":0,"redactions":0}"#
  let snapshot = try HubJSON.decoder().decode(CallSnapshot.self,from:Data(text.utf8))
  #expect(snapshot.inputText == "合成中文🙂\n第二行")
  #expect(snapshot.missing == nil)
  #expect(CallSnapshot.missing("deleted")?.contains("已一并清空") == true)
  #expect(CallSnapshot.missing("not_recorded")?.contains("无法还原") == true)
}
