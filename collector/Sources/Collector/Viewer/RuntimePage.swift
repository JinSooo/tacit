import SwiftUI
import CollectorCore

struct RuntimePage: View {
  @State private var section = "models"
  var body: some View {
    VStack(spacing: 0) {
      Picker(L10n.runLogType, selection: $section) {
        Text(L10n.modelSummaries).tag("models")
        Text(L10n.aiToolReads).tag("reads")
        Text(L10n.backgroundActivity).tag("background")
      }.pickerStyle(.segmented).frame(maxWidth: 460).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
      Group {
        if section == "models" { ModelCallsPage() }
        else if section == "reads" { AuditPage() }
        else { BackgroundCallsPage() }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.paper).navigationTitle(L10n.runLog)
  }
}

private struct ModelCallsPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var calls: [ModelCall] = []
  @State private var cursor: String?
  @State private var error: String?
  @State private var busy = false
  @State private var selected: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(L10n.callRetentionExplanation)
          .font(.system(size:TextSize.body)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
        if let error { Text(error).foregroundStyle(Palette.attention).textSelection(.enabled) }
        if calls.isEmpty && !busy && error == nil { Placeholder(kind:.empty("clock", L10n.noModelCallsYet)).frame(height:240) }
        LazyVStack(spacing:0) {
          ForEach(calls) { call in
            if call.id != calls.first?.id { Divider().padding(.horizontal,16) }
            ModelCallRow(call:call,expanded:selected == call.id) { selected = selected == call.id ? nil : call.id }
          }
        }.card()
        if busy { ProgressView().frame(maxWidth:.infinity) }
        else if cursor != nil { Button(L10n.loadMore) { Task { await load(reset:false) } }.frame(maxWidth:.infinity) }
      }
      .frame(maxWidth:1080,alignment:.leading).padding(.horizontal,32).padding(.vertical,24).frame(maxWidth:.infinity)
    }.task {
      // 页面自己刷新；展开了某次调用或加载过更多时不重排列表。
      await load(reset:true)
      while !Task.isCancelled {
        await WindowVisibility.pause(.seconds(30))
        if selected == nil, !loadedMore { await load(reset:true) }
      }
    }
  }
  @State private var loadedMore = false
  private func load(reset: Bool) async {
    guard !busy else { return }; busy = true; defer { busy = false }
    do {
      let page = try await store.api.modelCalls(cursor:reset ? nil : cursor)
      calls = reset ? page.calls : calls + page.calls.filter { item in !calls.contains(where: { $0.id == item.id }) }
      cursor = page.nextCursor; error = nil
      if !reset { loadedMore = true }
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}

private struct ModelCallRow: View {
  let call: ModelCall
  let expanded: Bool
  let toggle: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:0) {
      Button { Motion.animate { toggle() } } label: {
        HStack(alignment:.top,spacing:16) {
          VStack(alignment:.leading,spacing:5) {
            Text(call.title).font(.system(size:TextSize.body,weight:.medium)).foregroundStyle(Palette.ink)
            Text(call.model ?? L10n.modelUnknown).font(.system(size:TextSize.caption)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
            Text(call.status).font(.system(size:TextSize.body)).foregroundStyle(call.error == nil ? Palette.muted : Palette.attention)
          }
          Spacer(minLength:8)
          VStack(alignment:.trailing,spacing:5) {
            Text(call.date.map { ViewerFormat.dayTitle($0) + " " + ViewerFormat.clock($0) } ?? call.at)
            Text(call.elapsed)
          }.font(.system(size:TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          DisclosureChevron(expanded: expanded, size: 12, sideways: true).foregroundStyle(Palette.muted)
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel([call.title, call.status].joined(separator: L10n.comma)).accessibilityValue(expanded ? L10n.expanded : L10n.closed)
      if expanded {
        VStack(alignment:.leading,spacing:12) {
          Text(L10n.callTokens(input: call.inputTokens, output: call.outputTokens))
            .font(.system(size:TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          Text(L10n.callStates(provider: call.providerState, validation: call.validationState))
            .font(.system(size:TextSize.body)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
          if let error = call.error { Text(ModelErrorText.plain(error)).foregroundStyle(Palette.attention).textSelection(.enabled) }
          if let missing = CallSnapshot.missing(call.contentState), call.contentState == "not_recorded" {
            Text(missing).foregroundStyle(Palette.muted)
          } else { RuntimeSnapshotView(id:call.id) }
        }.font(.system(size:TextSize.body)).padding(.horizontal,16).padding(.bottom,16)
      }
    }
  }
}

struct RuntimeSnapshotView: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var snapshot: CallSnapshot?
  @State private var error: String?
  @State private var inputOpen = true
  @State private var outputOpen = false
  var body: some View {
    VStack(alignment:.leading,spacing:12) {
      if let error { Text(error).foregroundStyle(Palette.attention) }
      else if let snapshot {
        if let missing = snapshot.missing { Text(missing).foregroundStyle(Palette.muted) }
        else {
          if snapshot.kind != "context" {
            Text(snapshot.transport == "cli" ? L10n.commandLineSnapshotExplanation : L10n.apiSnapshotExplanation)
              .foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
          }
          if snapshot.redactions > 0 { Text(L10n.snapshotRedactions(snapshot.redactions)).foregroundStyle(Palette.muted) }
          DisclosureGroup(snapshot.kind == "context" ? L10n.savedSessionContext : L10n.request, isExpanded:$inputOpen) { code(snapshot.inputText) }
          if snapshot.kind != "context" {
            DisclosureGroup(snapshot.responseTruncated.value ? L10n.truncatedResponse(128_000) : L10n.response,isExpanded:$outputOpen) {
              if let response = snapshot.response { code(response) } else { Text(L10n.noResponseToShowYet).foregroundStyle(Palette.muted) }
            }
          }
        }
      } else { ProgressView().controlSize(.small) }
    }.font(.system(size:TextSize.body))
    .task(id:id) {
      snapshot = nil; error = nil
      while !Task.isCancelled {
        do { let value = try await store.api.callSnapshot(id); if !Task.isCancelled { snapshot = value; error = nil } }
        catch is CancellationError { break }
        catch { snapshot = nil; self.error = error.localizedDescription }
        await WindowVisibility.pause(.seconds(5))
      }
    }
  }
  private func code(_ text: String) -> some View {
    ScrollView {
      Text(text).font(.system(size:TextSize.caption,design:.monospaced)).textSelection(.enabled)
        .frame(maxWidth:.infinity,alignment:.leading).padding(12)
    }.frame(maxHeight:320).background(Palette.paper).clipShape(RoundedRectangle(cornerRadius:Radius.control))
  }
}

private struct BackgroundCallsPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var source = "hub"
  @State private var page: BackgroundLogPage?
  @State private var error: String?
  var body: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:16) {
        HStack {
          Picker(L10n.source,selection:$source) { Text(L10n.backgroundService).tag("hub"); Text(L10n.summaries).tag("distill"); Text(L10n.activityCapture).tag("collector") }.frame(maxWidth:240)
          Spacer()
        }
        Text(L10n.backgroundLogExplanation).font(.system(size:TextSize.body)).foregroundStyle(Palette.muted)
        if let error { Text(error).foregroundStyle(Palette.attention) }
        else if let page {
          if page.events.isEmpty { Placeholder(kind:.empty("clock",L10n.emptyBackgroundLog)).frame(height:240) }
          ForEach(Array(page.events.enumerated()),id:\.offset) { _,event in
            Text(event.prettyJSON).font(.system(size:TextSize.caption,design:.monospaced)).textSelection(.enabled)
              .frame(maxWidth:.infinity,alignment:.leading).padding(16).card()
          }
        } else { ProgressView().frame(maxWidth:.infinity) }
      }.frame(maxWidth:1080,alignment:.leading).padding(32).frame(maxWidth:.infinity)
    }.task(id: source) {
      page = nil; error = nil
      // 运行状态自己刷新，不放刷新按钮。
      while !Task.isCancelled {
        do { let value = try await store.api.backgroundLog(source); if !Task.isCancelled { page = value; error = nil } }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
        await WindowVisibility.pause(.seconds(15))
      }
    }
  }
}
