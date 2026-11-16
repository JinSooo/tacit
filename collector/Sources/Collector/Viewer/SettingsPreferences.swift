import SwiftUI

/// 草稿属于窗口，不随分组切换丢失；只提交当前分组修改的字段。
@MainActor @Observable final class SettingsPreferences {
  var saved: GeneralSettingsInfo?
  var draft: GeneralSettingsInfo?
  var error: String?
  var message: String?
  var busy = false

  func changed(context: Bool) -> Bool {
    guard let d = draft, let s = saved else { return false }
    return context ? d.injectTokens != s.injectTokens : d.archiveDays != s.archiveDays
  }
  func restore(context: Bool) {
    if context { draft?.injectTokens = 800 }
    else { draft?.archiveDays = 7 }
    message = nil
  }
  func revert(context: Bool) {
    guard let saved else { return }
    if context { draft?.injectTokens = saved.injectTokens }
    else { draft?.archiveDays = saved.archiveDays }
    error = nil; message = nil
  }
  func load(api: HubAPI) async {
    guard draft == saved, !busy else { return }
    do { let g = try await api.generalSettings(); saved = g; draft = g; error = nil }
    catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
  func save(api: HubAPI, context: Bool) async {
    guard let d = draft else { return }
    busy = true; error = nil; message = nil
    defer { busy = false }
    do {
      let values = context ? ["inject_tokens": d.injectTokens] : ["archive_days": d.archiveDays]
      for (key, value) in values {
        if let range = d.ranges[key], !(range[0]...range[1]).contains(value) {
          error = "请输入 \(range[0])–\(range[1]) 之间的整数。"; return
        }
      }
      let g = try await api.saveGeneral(values)
      // 另一个分组可能也有尚未保存的草稿。
      var next = g
      if context && changed(context: false) { next.archiveDays = d.archiveDays }
      if !context && changed(context: true) { next.injectTokens = d.injectTokens }
      saved = g; draft = next
      message = context ? "已保存，下次带入项目进展时生效。" : "已保存，下次整理时生效。"
    } catch { self.error = error.localizedDescription }
  }
}
