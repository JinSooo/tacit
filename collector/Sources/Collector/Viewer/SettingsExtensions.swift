import CollectorCore
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
      Text(updating == nil ? L10n.Settings.installSource : L10n.Settings.updateSource).font(.system(size: TextSize.title, weight: .semibold))
      if let preview = model.preview {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("\(preview.manifest.name)  \(preview.manifest.version)").font(.system(size: TextSize.body, weight: .semibold))
            Text(preview.manifest.description)
            if let revision = preview.revision {
              Text(L10n.Settings.revision(revision, previous: false)).textSelection(.enabled).font(.system(size: TextSize.caption))
              if let previous = preview.previousRevision { Text(L10n.Settings.revision(previous, previous: true)).textSelection(.enabled).font(.system(size: TextSize.caption)) }
            }
            PluginPermissions(manifest: preview.manifest, values: values)
            PluginFields(manifest: preview.manifest, values: $values, invalidNumbers: $invalidNumbers)
            Note(L10n.Settings.pluginPermissionNote)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
          Button(L10n.Settings.chooseAgain) { Task { _ = await model.send(PluginRequest(action: "discard", ticket: preview.ticket), store: store) } }.disabled(model.busy)
          Spacer()
          Button(preview.updating ? L10n.Settings.confirmPluginUpdate : L10n.Settings.confirmPluginInstall) {
            Task {
              let request = PluginRequest(action: "install", id: preview.manifest.id, ticket: preview.ticket, values: values)
              if await model.send(request, store: store) != nil { dismiss() }
            }
          }.buttonStyle(.borderedProminent).disabled(model.busy || !invalidNumbers.isEmpty)
        }
      } else {
        Text(L10n.Settings.pluginManifestNote)
          .foregroundStyle(Palette.muted)
        TextField(L10n.Settings.pluginLocation, text: $source).textFieldStyle(.roundedBorder).disabled(updating != nil)
        HStack {
          if updating == nil { Button(L10n.Settings.chooseLocalFolder) { chooseFolder() } }
          Spacer()
          Button(L10n.Settings.previewPermissions) { Task { _ = await model.send(PluginRequest(action: "prepare", source: source, id: updating?.id), store: store) } }
            .buttonStyle(.borderedProminent).disabled(model.busy || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      if model.busy { ProgressView(L10n.Settings.processing).controlSize(.small) }
      if let error = model.error { SettingsMessage(text: error) }
      HStack { Spacer(); Button(L10n.Settings.cancel) { Task { if let p = model.preview { _ = await model.send(PluginRequest(action: "discard", ticket: p.ticket), store: store) }; dismiss() } }.disabled(model.busy) }
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
  var values: [String: PluginValue] = [:]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.Settings.pluginPurpose).fontWeight(.semibold)
      if manifest.permissions.isEmpty { Text(L10n.Settings.noExtraPermissions).foregroundStyle(Palette.muted) }
      ForEach(manifest.permissions, id: \.self) { Text("• " + $0) }
      Text(L10n.Settings.allowedReadScope).fontWeight(.semibold)
      let files = manifest.access?.readFiles ?? []
      let directories = manifest.access?.readDirectories ?? []
      if files.isEmpty && directories.isEmpty {
        Text(L10n.Settings.legacyPluginNote).foregroundStyle(Palette.muted)
      }
      ForEach(files + directories, id: \.self) { key in
        let label = manifest.config.first(where: { $0.key == key })?.label ?? key
        let path = values[key]?.text ?? manifest.config.first(where: { $0.key == key })?.default?.text ?? ""
        Text(L10n.Settings.readPath(label, path: path, includesSubfolders: directories.contains(key))).textSelection(.enabled)
      }
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
              Text(field.label + (field.required == true ? L10n.Settings.requiredSuffix : ""))
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
            if invalidNumbers.contains(field.key) { Text(L10n.Settings.invalidNumber).foregroundStyle(Palette.attention) }
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
    Section(L10n.Settings.pluginInfo) {
      Text(plugin.manifest.description)
      SettingsRow(L10n.Settings.version, value: plugin.manifest.version)
      SettingsRow(L10n.Settings.installOrigin) { Text(plugin.origin).textSelection(.enabled).lineLimit(nil) }
      if let revision = plugin.revision { SettingsRow(L10n.Settings.pinnedRevision) { Text(revision).textSelection(.enabled).lineLimit(nil) } }
      PluginPermissions(manifest: plugin.manifest, values: values)
      Button(L10n.Settings.openSystemPrivacy) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(url) } }
      Note(L10n.Settings.pluginScopeNote)
    }
    if !plugin.manifest.config.isEmpty {
      Section(L10n.Settings.configuration) {
        PluginFields(manifest: plugin.manifest, values: $values, invalidNumbers: $invalidNumbers).id(formRevision)
        Button(L10n.Settings.confirmScopeSave) { Task { _ = await model.send(PluginRequest(action: "configure", id: plugin.id, values: values), store: store) } }
          .disabled(model.busy || values == plugin.values || !invalidNumbers.isEmpty)
      }
    }
    Section(L10n.Settings.manage) {
      HStack {
        Button(L10n.Settings.checkPluginUpdate) { model.preview = nil; model.error = nil; update = true }.disabled(model.busy)
        Button(L10n.Settings.uninstall, role: .destructive) { uninstall = true }.disabled(model.busy)
      }
      if model.busy { ProgressView().controlSize(.small) }
      if let message = model.message { SettingsMessage(text: message, warning: false) }
      if let error = model.error { SettingsMessage(text: error) }
    }
    .onAppear { values = plugin.values }
    .onChange(of: plugin) { _, next in values = next.values; invalidNumbers = []; formRevision += 1 }
    .sheet(isPresented: $update) { ExtensionInstallView(updating: plugin).environment(store) }
    .confirmationDialog(L10n.Settings.uninstallQuestion(plugin.manifest.name), isPresented: $uninstall) {
      Button(L10n.Settings.uninstallKeepRecords) { remove(false) }
      Button(L10n.Settings.uninstallDeleteRecords, role: .destructive) { remove(true) }
      Button(L10n.Settings.cancel, role: .cancel) {}
    } message: { Text(L10n.Settings.pluginDeleteNote) }
  }
  func remove(_ records: Bool) { Task { _ = await store.extensions.send(PluginRequest(action: "uninstall", id: plugin.id, deleteRecords: records), store: store) } }
}
