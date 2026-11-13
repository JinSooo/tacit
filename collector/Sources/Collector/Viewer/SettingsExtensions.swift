import AppKit
import SwiftUI

struct ExtensionInstallView: View {
  @Environment(ViewerStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var source = ""
  @State private var values: [String: PluginValue] = [:]
  @State private var invalidNumbers = Set<String>()
  let updating: ExtensionPlugin?
  private var sheetHeight: CGFloat {
    guard let preview = store.extensions.preview else { return 270 }
    let fields = preview.manifest.config.count
    let permissions = preview.manifest.permissions.count
    return CGFloat(min(620, 360 + fields * 60 + permissions * 30))
  }

  var body: some View {
    let model = store.extensions
    VStack(alignment: .leading, spacing: 16) {
      Text(updating == nil ? "安装数据源" : "更新数据源").font(.system(size: TextSize.title, weight: .semibold))
      if let preview = model.preview {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("\(preview.manifest.name)  \(preview.manifest.version)").font(.system(size: TextSize.body, weight: .semibold))
            Text(preview.manifest.description)
            if let revision = preview.revision {
              Text("固定提交：" + revision).textSelection(.enabled).font(.system(size: TextSize.caption))
              if let previous = preview.previousRevision { Text("原提交：" + previous).textSelection(.enabled).font(.system(size: TextSize.caption)) }
            }
            PluginPermissions(manifest: preview.manifest)
            PluginFields(manifest: preview.manifest, values: $values, invalidNumbers: $invalidNumbers)
            Note("安装后默认停用。插件代码以你的本机权限运行，只安装你信任的来源。记录入库前会过滤黑名单与密钥。")
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
          Button("重新选择") { Task { _ = await model.send(PluginRequest(action: "discard", ticket: preview.ticket), store: store) } }.disabled(model.busy)
          Spacer()
          Button(preview.updating ? "确认更新并停用" : "确认权限并安装") {
            Task {
              let request = PluginRequest(action: "install", id: preview.manifest.id, ticket: preview.ticket, values: values)
              if await model.send(request, store: store) != nil { dismiss() }
            }
          }.buttonStyle(.borderedProminent).disabled(model.busy || !invalidNumbers.isEmpty)
        }
      } else {
        Text("选择带有 plugin.json 清单的目录，或填写 Git 仓库地址。这里只读取清单，不会运行插件。")
          .foregroundStyle(Palette.muted)
        TextField("本地目录或 https://、ssh:// Git 地址", text: $source).textFieldStyle(.roundedBorder).disabled(updating != nil)
        HStack {
          if updating == nil { Button("选择本地目录…") { chooseFolder() } }
          Spacer()
          Button("预览权限与配置") { Task { _ = await model.send(PluginRequest(action: "prepare", source: source, id: updating?.id), store: store) } }
            .buttonStyle(.borderedProminent).disabled(model.busy || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      if model.busy { ProgressView("正在处理…").controlSize(.small) }
      if let error = model.error { SettingsMessage(text: error) }
      HStack { Spacer(); Button("取消") { Task { if let p = model.preview { _ = await model.send(PluginRequest(action: "discard", ticket: p.ticket), store: store) }; dismiss() } }.disabled(model.busy) }
    }
    .padding(24).frame(width: 560, height: sheetHeight)
    .interactiveDismissDisabled(model.busy)
    .onDisappear {
      if let p = model.preview, !model.busy { Task { _ = await model.send(PluginRequest(action: "discard", ticket: p.ticket), store: store) } }
    }
    .onAppear { source = updating?.origin ?? ""; model.error = nil }
    .onChange(of: model.preview?.ticket) { _, _ in values = model.preview?.values ?? [:]; invalidNumbers = [] }
  }
  func chooseFolder() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    let handler: (NSApplication.ModalResponse) -> Void = { response in if response == .OK { source = panel.url?.path ?? "" } }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
  }
}

struct PluginPermissions: View {
  let manifest: ExtensionManifest
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("插件声明的读取范围与权限").fontWeight(.semibold)
      if manifest.permissions.isEmpty { Text("未声明额外权限").foregroundStyle(Palette.muted) }
      ForEach(manifest.permissions, id: \.self) { Text("• " + $0) }
    }
  }
}
struct PluginFields: View {
  let manifest: ExtensionManifest
  @Binding var values: [String: PluginValue]
  @Binding var invalidNumbers: Set<String>
  @State private var numberText: [String: String] = [:]
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(manifest.config) { field in
        VStack(alignment: .leading, spacing: 4) {
          if field.type == "boolean" {
            Toggle(field.label, isOn: Binding(get: { (values[field.key] ?? field.default)?.bool ?? false }, set: { values[field.key] = .boolean($0) }))
          } else {
            HStack {
              Text(field.label + (field.required == true ? "（必填）" : ""))
              Spacer()
              TextField(field.label, text: Binding(get: { numberText[field.key] ?? (values[field.key] ?? field.default)?.text ?? "" }, set: { text in
                if field.type == "number" {
                  numberText[field.key] = text
                  if text.isEmpty { values[field.key] = nil; invalidNumbers.remove(field.key) }
                  else if let n = Double(text), n.isFinite { values[field.key] = .number(n); invalidNumbers.remove(field.key) }
                  else { invalidNumbers.insert(field.key) }
                } else { values[field.key] = .string(text) }
              })).textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(field.label).frame(maxWidth: 280)
            }
            if invalidNumbers.contains(field.key) { Text("请输入有效数字").foregroundStyle(Palette.attention) }
          }
          if let description = field.description { Note(description) }
        }
      }
    }
  }
}
struct ExtensionDetailSettings: View {
  @Environment(ViewerStore.self) private var store
  let plugin: ExtensionPlugin
  @State private var values: [String: PluginValue] = [:]
  @State private var invalidNumbers = Set<String>()
  @State private var formRevision = 0
  @State private var update = false
  @State private var uninstall = false
  var body: some View {
    let model = store.extensions
    Section("插件信息") {
      Text(plugin.manifest.description)
      SettingsRow("版本", value: plugin.manifest.version)
      SettingsRow("安装来源") { Text(plugin.origin).textSelection(.enabled).lineLimit(nil) }
      if let revision = plugin.revision { SettingsRow("固定提交") { Text(revision).textSelection(.enabled).lineLimit(nil) } }
      PluginPermissions(manifest: plugin.manifest)
      Button("打开系统隐私设置…") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(url) } }
      Note("权限清单由插件声明。插件以你的本机权限运行，系统权限仍需在系统设置中授权。")
    }
    if !plugin.manifest.config.isEmpty {
      Section("配置") {
        PluginFields(manifest: plugin.manifest, values: $values, invalidNumbers: $invalidNumbers).id(formRevision)
        Button("保存配置") { Task { _ = await model.send(PluginRequest(action: "configure", id: plugin.id, values: values), store: store) } }
          .disabled(model.busy || values == plugin.values || !invalidNumbers.isEmpty)
      }
    }
    Section("管理") {
      HStack {
        Button("检查并更新…") { model.preview = nil; model.error = nil; update = true }.disabled(model.busy)
        Button("卸载…", role: .destructive) { uninstall = true }.disabled(model.busy)
      }
      if model.busy { ProgressView().controlSize(.small) }
      if let message = model.message { SettingsMessage(text: message, warning: false) }
      if let error = model.error { SettingsMessage(text: error) }
    }
    .onAppear { values = plugin.values }
    .onChange(of: plugin) { _, next in values = next.values; invalidNumbers = []; formRevision += 1 }
    .sheet(isPresented: $update) { ExtensionInstallView(updating: plugin).environment(store) }
    .confirmationDialog("卸载“\(plugin.manifest.name)”？", isPresented: $uninstall) {
      Button("卸载，保留记录") { remove(false) }
      Button("卸载并删除它的全部记录", role: .destructive) { remove(true) }
      Button("取消", role: .cancel) {}
    } message: { Text("插件会先停用。删除记录不能恢复，相关事项与总结会按剩余记录重新整理。") }
  }
  func remove(_ records: Bool) { Task { _ = await store.extensions.send(PluginRequest(action: "uninstall", id: plugin.id, deleteRecords: records), store: store) } }
}
