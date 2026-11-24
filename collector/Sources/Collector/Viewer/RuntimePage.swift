import SwiftUI
import CollectorCore

struct RuntimePage: View {
  @State private var section = "models"
  var body: some View {
    VStack(spacing: 0) {
      Picker("运行记录类型", selection: $section) {
        Text("模型整理").tag("models")
        Text("AI 工具读取").tag("reads")
        Text("后台运行").tag("background")
      }.pickerStyle(.segmented).frame(maxWidth: 460).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
      Group {
        if section == "models" { ModelCallsPage() }
        else if section == "reads" { AuditPage() }
        else { BackgroundCallsPage() }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.paper).navigationTitle("运行记录")
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
        Text("正文在本机保存 7 天。删除任一历史记录时，所有调用正文会一并清空，时间和状态保留。")
          .font(.system(size:TextSize.body)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
        if let error { Text(error).foregroundStyle(Palette.attention).textSelection(.enabled) }
        if calls.isEmpty && !busy && error == nil { Placeholder(kind:.empty("clock", "还没有模型调用")).frame(height:240) }
        LazyVStack(spacing:0) {
          ForEach(calls) { call in
            if call.id != calls.first?.id { Divider().padding(.horizontal,16) }
            ModelCallRow(call:call,expanded:selected == call.id) { selected = selected == call.id ? nil : call.id }
          }
        }.card()
        if busy { ProgressView().frame(maxWidth:.infinity) }
        else if cursor != nil { Button("加载更多") { Task { await load(reset:false) } }.frame(maxWidth:.infinity) }
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
      Button(action:toggle) {
        HStack(alignment:.top,spacing:16) {
          VStack(alignment:.leading,spacing:5) {
            Text(call.title).font(.system(size:TextSize.body,weight:.medium)).foregroundStyle(Palette.ink)
            Text(call.model ?? "模型未记录").font(.system(size:TextSize.caption)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
            Text(call.status).font(.system(size:TextSize.body)).foregroundStyle(call.error == nil ? Palette.muted : Palette.attention)
          }
          Spacer(minLength:8)
          VStack(alignment:.trailing,spacing:5) {
            Text(call.date.map { ViewerFormat.dayTitle($0) + " " + ViewerFormat.clock($0) } ?? call.at)
            Text(call.elapsed)
          }.font(.system(size:TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          PhIcon(expanded ? "caret-down" : "caret-right",size:12).foregroundStyle(Palette.muted)
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("\(call.title)，\(call.status)").accessibilityValue(expanded ? "已展开" : "已收起")
      if expanded {
        VStack(alignment:.leading,spacing:12) {
          Text("输入 \(call.inputTokens.map(String.init) ?? "未知") / 输出 \(call.outputTokens.map(String.init) ?? "未知") token")
            .font(.system(size:TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          Text("返回：\(call.providerState == "returned" ? "已返回" : call.providerState == "sending" ? "等待中" : "失败或未发送")　校验：\(call.validationState == "passed" ? "通过" : call.validationState == "failed" ? "未通过" : "未记录")")
            .font(.system(size:TextSize.body)).foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
          if let error = call.error { Text(error).foregroundStyle(Palette.attention).textSelection(.enabled) }
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
            Text(snapshot.transport == "cli" ? "这是交给命令行工具的内容；工具内部附加的说明和网络请求不可见。" : "这是交给模型服务的请求正文，认证凭据不在其中。")
              .foregroundStyle(Palette.muted).fixedSize(horizontal:false,vertical:true)
          }
          if snapshot.redactions > 0 { Text("已隐藏 \(snapshot.redactions) 处可能的密钥。").foregroundStyle(Palette.muted) }
          DisclosureGroup(snapshot.kind == "context" ? "当时自动带入的内容" : "发送内容", isExpanded:$inputOpen) { code(snapshot.inputText) }
          if snapshot.kind != "context" {
            DisclosureGroup(snapshot.responseTruncated.value ? "返回内容（仅保留前 128000 字符）" : "返回内容",isExpanded:$outputOpen) {
              if let response = snapshot.response { code(response) } else { Text("尚无可展示的返回内容。").foregroundStyle(Palette.muted) }
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
          Picker("来源",selection:$source) { Text("后台服务").tag("hub"); Text("内容整理").tag("distill"); Text("活动采集").tag("collector") }.frame(maxWidth:240)
          Spacer()
        }
        Text("展示最近的结构化状态与计数。含原文的诊断行不会显示在这里。").font(.system(size:TextSize.body)).foregroundStyle(Palette.muted)
        if let error { Text(error).foregroundStyle(Palette.attention) }
        else if let page {
          if page.events.isEmpty { Placeholder(kind:.empty("clock","暂时没有可展示的运行状态")).frame(height:240) }
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
