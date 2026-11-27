import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import CollectorCore

/// 菜单栏采集端。所有读取都在这里做，hub 只接收数据。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  /// 第二个实例启动时发这个通知，请已在运行的采集端打开窗口。
  static let showWindowNotification = "dev.record-anything.collector.show-window"
  let config: Config

  init(config: Config) { self.config = config }
  let toggles = SourceToggles(store: UserDefaults.standard)
  lazy var sources = DataSourceRegistry(toggles: toggles)
  lazy var remoteAccess = RemoteDeviceAccess(dataDirectory: config.dataDir, writeGate: switchWriteGate)
  lazy var deviceSession = HostDeviceSession(
    origin: { [config] in config.hubURL },
    files: LocalDeviceLink.Files(directory: config.dataDir),
    keys: .keychain, remoteAccess: remoteAccess
  )
  let switchWriteGate = RemoteSwitchWriteGate()
  lazy var remotePairing = RemotePairing(dataDirectory: config.dataDir)
  lazy var hub = HubClient(config: config, deviceSession: deviceSession, writeGate: switchWriteGate, onHealthEvent: { [weak self] in
    nonisolated(unsafe) let delegate = self
    DispatchQueue.main.async { delegate?.writeStatus() }
  }, onLinked: { [weak self] _ in
    nonisolated(unsafe) let delegate = self
    DispatchQueue.main.async {
      guard let source = delegate?.viewerDataSource else { return }
      Task { await source.activateIfLinked() }
    }
    DispatchQueue.main.async { delegate?.writeStatus(forceReport: true) }
  })
  lazy var api = HubAPI(base: { [config] in config.hubURL }, token: { [config] in config.token },
                        deviceAction: { [weak self] op, body, timeout, route in
    try await self?.viewerDataSource.sendAction(op: op, body: body, timeout: timeout, on: route)
  }, hubRoute: { [config] in try config.hubRoute() }, writeGate: switchWriteGate)
  lazy var viewerDataSource: AdaptiveViewerDataSource = {
    let widgetURL = WidgetSnapshot.fileURL.flatMap { file in
      file.deletingLastPathComponent().deletingLastPathComponent().path == config.dataDir.standardizedFileURL.path ? file : nil
    }
    return AdaptiveViewerDataSource(
      http: HTTPViewerDataSource(api: api),
      dataDir: config.dataDir,
      originProvider: { [config] in config.hubURL },
      widgetSnapshotURL: widgetURL,
      onUpdate: { [weak self] result in
        let delegate = self
        await MainActor.run {
          guard let delegate, !delegate.terminating else { return }
          delegate.widgetPublisher?.refresh()
          let needsReload = result.deletedCount > 0 || !result.goneRecordIDs.isEmpty || result.didReset
          delegate.viewer.store.applyRemoteSync(reloadViews: needsReload)
        }
      },
      onWipe: { [weak self] reason in
        let delegate = self
        await MainActor.run {
          guard let delegate, !delegate.terminating else { return }
          if !delegate.config.allowsLocalHub, reason == .deviceRemoved || reason == .roleDowngraded {
            delegate.resetViewerForBindingChange()
          } else {
            delegate.widgetPublisher?.clearSnapshot()
          }
        }
      },
      remoteAccess: remoteAccess,
      onBindingChanged: { [weak self] in
        let delegate = self
        await MainActor.run { delegate?.resetViewerForBindingChange() }
      }
    )
  }()
  @MainActor private lazy var deviceDiscovery = DeviceDiscovery(advertiser: BonjourDeviceAdvertiser())
  lazy var audio = AudioCoordinator(config: config, deviceSession: deviceSession, writeGate: switchWriteGate)
  lazy var plugins = PluginScheduler(config: config, deviceSession: deviceSession, writeGate: switchWriteGate)
  private lazy var loginStartup = LoginStartup(home: FileManager.default.homeDirectoryForCurrentUser, dataDir: config.dataDir,
                                              beginWrite: switchWriteGate.begin, endWrite: switchWriteGate.end)
  @MainActor lazy var historyImporter = HistoryImporter(directory: config.dataDir, gate: switchWriteGate, operations: .init(
    binding: { [config] in try HubBinding.read(from: config.dataDir) },
    budget: { [unowned self] route in
      guard let session = try await self.deviceSession.connection(for: route)?.remoteSession else {
        throw HistoryImporter.Failure.offline
      }
      return try await session.historyImportRecordBudget()
    },
    send: { [unowned self] route, op, body in
      guard let connection = try await self.deviceSession.connection(for: route) else { throw HistoryImporter.Failure.offline }
      return try await connection.client.send(op: op, body: body, timeout: 12).bodyData
    },
    export: { [config] cursor, limit in
      guard let runtime = config.repo else { throw FrozenHistoryCommands.Failure.subprocess }
      return try await FrozenHistoryCommands(runtime: runtime, bun: config.bun, directory: config.dataDir)
        .export(after: cursor, limit: limit)
    },
    apply: { [config] changes in
      guard let runtime = config.repo else { throw FrozenHistoryCommands.Failure.subprocess }
      try await FrozenHistoryCommands(runtime: runtime, bun: config.bun, directory: config.dataDir).apply(changes)
    },
    mayImport: { [unowned self] route in await self.hub.mayImportHistory(on: route) },
    deviceID: { [config] remote in try RemoteDeviceLink.read(from: config.dataDir, identity: remote).device_id }
  ))

  func previewLocalHistory() async throws -> LocalHistoryPreview {
    try await LocalHistoryPreview.load(config: config)
  }

  func previewSwitchBackPendingCount() async throws -> Int {
    try await hub.switchBackPendingCount(on: config.hubRoute())
  }

  @MainActor private func returnToLocal(allowEmptyHistory: Bool) async throws {
    let backup = try historyImporter.backupInfo()
    let empty = backup.recovery == .emptyLocalBackend
    guard empty == allowEmptyHistory else { throw RemoteSwitch.Failure.reconciliationIncomplete }
    try await remoteSwitch.switchBack(allowEmptyHistory: empty, preflight: { [unowned self] _ in
      let current = try self.historyImporter.backupInfo()
      return current.recovery == backup.recovery
    }, reconcile: { [unowned self] route in
      let result = await self.historyImporter.reconcileForReturn(on: route)
      return result == (empty ? .emptyLocalBackend : .reconciled)
    })
    await historyImporter.tick()
  }

  @MainActor lazy var remoteSwitch = RemoteSwitch(
    persistence: DiskRemoteSwitchPersistence(directory: config.dataDir),
    services: LaunchdRemoteSwitchServices(config: config, startup: loginStartup),
    runtime: .init(gate: switchWriteGate, settled: { [unowned self] in
      guard await remoteAccess.isMailboxIdleForSwitch(), await audio.isSettledForSwitch() else { return false }
      return try await hub.settleForSwitch()
    }, suspendBonjour: { [unowned self] suspended in
      deviceDiscovery.setSuspended(suspended)
    }, publish: { [unowned self] previousLocal, from, to, publish in
      try await hub.publishSwitch(previousLocal: previousLocal, from: from, to: to) {
        try self.audio.publishSwitch(to: to, commit: publish)
      }
    }, bindingChanged: { [unowned self] in
      await viewerDataSource.refreshBindingAfterSwitch()
      viewer.store.remoteBackend?.refreshContext()
      Task { @MainActor [weak self] in await self?.historyImporter.tick() }
    }, finishCommit: { [unowned self] local, remote in
      try await hub.finishSwitchToRemote(from: local, to: remote)
    }, finishReturn: { [unowned self] previousLocal, remote, local in
      try await hub.finishSwitchBack(previousLocal: previousLocal, remote: remote, local: local)
    }),
    pairing: remotePairing
  )
  @MainActor private func makeRemoteBackendSettings() -> RemoteBackendSettingsModel {
    let directory = config.dataDir
    let persistence = DiskRemoteSwitchPersistence(directory: directory)
    return RemoteBackendSettingsModel(operations: .init(
      context: { [unowned self] in
        let binding = try persistence.binding()
        let replacement = try remotePairing.retainedReplacement(for: binding)
        let link = replacement?.collectorLink ?? binding.remote.flatMap { try? RemoteDeviceLink.read(from: directory, identity: $0) }
        var frozen = false
        do { try remoteAccess.validate(binding.route) }
        catch RemoteDeviceAccess.Failure.frozen { frozen = true }
        return .init(binding: binding, link: link, checkpoint: try persistence.checkpoint()?.step,
                     agentNeedsDirect: binding.remote.map { !persistence.hasAgentLink(for: $0) } ?? false, frozen: frozen,
                     rePairing: try remoteSwitch.rePairingState(),
                     retained: binding.phase == .local ? (try? remotePairing.retainedRemotes()) ?? [] : [],
                     cleanupRequired: !((try? remotePairing.remotesRequiringRePairingCleanup()) ?? []).isEmpty,
                     preparationUsesMailbox: try remotePairing.preparedUsesMailbox(binding))
      },
      prepare: { [unowned self] invitation, address, delivered in
        let parsed = try DevicePairingInvitation.parse(invitation)
        let identity = try HubBinding.Remote(hubID: parsed.hubID, hubPublicKey: parsed.hubPublicKeyBase64URL)
        let last = try? RemoteDeviceLink.read(from: directory, identity: identity).addresses.first
        return try await remotePairing.prepare(invitation: invitation, deviceName: Host.current().localizedName ?? "Mac",
          lastSuccessfulAddress: last, manualAddress: address, onMailboxDelivered: delivered)
      },
      prepareAgain: { [unowned self] invitation, address, delivered in
        try await remotePairing.prepareRePairing(invitation: invitation, deviceName: Host.current().localizedName ?? "Mac",
          manualAddress: address, onMailboxDelivered: delivered)
      },
      preparedAgain: { [unowned self] in try await remotePairing.preparedRePairing() },
      previewSwitch: { [unowned self] in
        async let history = self.previewLocalHistory()
        guard let devices = try await api.deviceSettings() else { throw HubError.needsLocalHub }
        return try await .init(history: history, phones: devices.displayedDevices.filter { $0.platform == "android" },
                               path: HistoryBackupFiles(directory: directory).database.path)
      },
      commit: { [unowned self] binding, prepared in
        if let prepared { try await remoteSwitch.commit(prepared: prepared) }
        else if let remote = binding.remote {
          let replacement = try remotePairing.retainedReplacement(for: binding)
          let needsDirect = replacement.map { $0.agentLink == nil } ?? !persistence.hasAgentLink(for: remote)
          try await remoteSwitch.commit(prepared: binding, agentNeedsDirectConnection: needsDirect)
        } else { throw HubBinding.Failure.changed }
      },
      commitAgain: { [unowned self] in try await remoteSwitch.commitRePairing($0) },
      cancel: { [unowned self] in try await remotePairing.cancelPreparation(replacing: $0) },
      reauthenticate: { [unowned self] manual in
        let route = try remoteAccess.route()
        guard let identity = route.remote else { throw RemoteDeviceAccess.Failure.unavailable }
        let link = try RemoteDeviceLink.read(from: directory, identity: identity)
        let endpoint = await ProjectionEndpointSelector.select(localPort: nil, inviteAddresses: link.addresses,
          manualAddresses: [manual].compactMap { $0 }, expectedHubID: identity.hub_id) { url, hubID in
            guard let direct = try? RemotePairing.DirectEndpoint(origin: url),
                  let hello = try? await direct.hello() else { return false }
            return hello.hubID == hubID && hello.v == DeviceProtocol.version
          }
        guard case .direct(let url) = endpoint else { throw RemoteDeviceAccess.Failure.unavailable }
        try await remoteAccess.reauthenticate(route, transport: DirectDeviceTransport(origin: url, requestTimeout: 5), authenticatedAddress: url)
        await viewerDataSource.refreshBindingAfterSwitch()
        hub.flush()
      },
      channel: { [unowned self] route in
        guard let session = try await deviceSession.connection(for: route)?.remoteSession else { return .unavailable }
        switch await session.connectionState() {
        case .unavailable: return .unavailable
        case .unconfirmed(.direct): return .unconfirmed(.direct)
        case .unconfirmed(.relay): return .unconfirmed(.relay)
        case .connected(.direct): return .connected(.direct)
        case .connected(.relay): return .connected(.relay)
        }
      },
      status: { [unowned self] in
        let result = await api.diagnosticStatus()
        guard let data = result.status else { throw HubError.remoteUnavailable }
        return try HubJSON.decoder().decode(RemoteBackendStatus.self, from: data)
      },
      pause: { [unowned self] paused in
        do { try await historyImporter.setPaused(paused); await historyImporter.refreshPresentation() }
        catch { await historyImporter.refreshPresentation(operationError: error); throw error }
      },
      deleteBackup: { [unowned self] in
        do { try await historyImporter.deleteBackup() }
        catch { await historyImporter.refreshPresentation(operationError: error); throw error }
      },
      previewReturn: { [unowned self] in try await previewSwitchBackPendingCount() },
      switchBack: { [unowned self] in try await returnToLocal(allowEmptyHistory: $0) },
      cancelReturn: { [unowned self] in try await remoteSwitch.cancelSwitchBack() },
      recover: { [unowned self] in try await remoteSwitch.recover() },
      reconnect: { [unowned self] link, address in
        let identity = try HubBinding.Remote(hubID: link.hub_id, hubPublicKey: link.hub_pk)
        return try await remotePairing.prepareRetained(remote: identity, manualAddress: address)
      },
      cancelRePairing: { [unowned self] in try await remoteSwitch.cancelRePairing() },
      retryIssue: { [unowned self] id in
        try await historyImporter.retryIssue(id: id)
        Task { @MainActor [weak self] in await self?.historyImporter.tick() }
      },
      keepIssue: { [unowned self] in try await historyImporter.abandonIssue(id: $0) },
      dismissCleanup: { [unowned self] in try await remotePairing.dismissRePairingCleanup() }
    ))
  }

  lazy var viewer: ViewerWindow = MainActor.assumeIsolated {
    let store = ViewerStore(api: api, dataSource: viewerDataSource, device: config.device, controls: self,
                            loginStartup: loginStartup, agentNeedsDirectConnection: { [weak self] in
      self?.remoteSwitch.agentNeedsDirectConnection ?? false
    })
    let backend = makeRemoteBackendSettings()
    store.remoteBackend = backend
    historyImporter.onChange = { [weak backend] progress, backup in
      backend?.updateImport(progress, backup: backup)
    }
    store.onRevision = { [weak self] in
      self?.viewerDataSource.notifyLocalWrite()
      self?.widgetPublisher?.refresh(invalidate: true)
    }
    store.onDeviceSettingsUpdate = { [weak self] settings, invitationHubId in
      guard let self, !self.terminating, self.config.allowsLocalHub else { return }
      self.deviceDiscovery.update(settings, invitationHubId: invitationHubId)
    }
    let window = ViewerWindow(store: store)
    window.onClose = { [weak self] in
      self?.viewerDataSource.clearMemory()
      self?.updateSyncForeground()
    }
    return window
  }
  @MainActor private func resetViewerForBindingChange() {
    guard !terminating else { return }
    widgetPublisher?.clearSnapshot()
    panel.close()
    viewer.store.resetForBindingChange()
    // Replace the root to discard view-local loaders and expanded raw records.
    viewer.replaceRoot()
    if !config.allowsLocalHub { deviceDiscovery.update(nil) }
    syncedLanguageRoute = nil
    syncLanguageIfNeeded()
    widgetPublisher?.refresh()
  }

  private var widgetPublisher: WidgetSnapshotPublisher?
  private var readyForTimelineURL = false
  private var pendingTimelineDay: Date?
  lazy var segmenter = Segmenter(device: config.device)
  lazy var wechat = WeChatCollector(device: config.device, ocr: ocr, send: { [weak self] in self?.hub.enqueue($0) })
  let ax = AXReader()
  let ocr = OCRReader()
  let captureQueue = DispatchQueue(label: "record-anything.capture", qos: .utility)

  var statusItem: NSStatusItem!
  let statusMenu = NSMenu()
  @MainActor private var languageSyncTask: Task<Void, Never>?
  @MainActor private var syncedLanguage: AppLanguage?
  @MainActor private var syncedLanguageRoute: HubBinding.Route?

  @MainActor private func syncLanguageIfNeeded() {
    guard !terminating, languageSyncTask == nil, let route = try? config.hubRoute() else { return }
    let language = LanguageStore.shared.resolved
    guard syncedLanguageRoute != route || syncedLanguage != language else { return }
    languageSyncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      // The device operation is admin-only. Local HTTP can also bootstrap with the local token.
      let saved = (try? await self.api.saveGeneral(["language": language.rawValue])) != nil
      self.languageSyncTask = nil
      if saved, (try? self.config.hubRoute()) == route {
        self.syncedLanguage = language
        self.syncedLanguageRoute = route
      }
      if LanguageStore.shared.resolved != language { self.syncLanguageIfNeeded() }
    }
  }
  lazy var panel: StatusPanel = MainActor.assumeIsolated {
    let p = StatusPanel(store: viewer.store) { [weak self] page in self?.viewer.show(page) }
    p.onVisibilityChange = { [weak self] visible in
      guard let self else { return }
      if !visible && !WindowVisibility.visible { self.viewerDataSource.clearMemory() }
      self.updateSyncForeground()
    }
    return p
  }

  @MainActor private func updateSyncForeground() {
    viewerDataSource.setForeground(WindowVisibility.visible || panel.isShown)
  }
  var timers: [Timer] = []
  var terminationSignal: TerminationSignal?
  var terminating = false
  var pausedUntil: Date?
  var ocrSchedule = OCRSchedule()
  // 以下只在主线程读写，给"上次运行"用。
  var lastScreen: Date?
  var lastOCRRun: Date?
  /// 维护任务（同步、导入）的进行状态，只在主线程读写。
  var jobs: [MaintenanceTask: CaptureSnapshot.Job] = [:]
  var managingPlugins = Set<String>()

  // 只计数，不含任何内容；写到 collector-status.json 便于排查和验收。
  var stats: [String: Int] = ["ticks": 0, "scanMsTotal": 0, "scanMsMax": 0, "truncated": 0,
                              "ocrRuns": 0, "ocrMsTotal": 0, "ocrLines": 0, "screenRecords": 0,
                              "skippedPolicy": 0, "skippedSecureInput": 0]

  func enabled(_ id: String) -> Bool { toggles.isEnabled(id) }

  func applicationDidFinishLaunching(_ n: Notification) {
    terminationSignal = TerminationSignal { NSApp.terminate(nil) }
    Task { @MainActor [weak self] in
      guard let self else { return }
      var recoveryMessage: String?
      do { try await self.remoteSwitch.recover() }
      catch {
        NSLog("record-anything: %@", error.localizedDescription)
        recoveryMessage = RemoteBackendSettingsModel.message(for: error, fallback: L10n.Settings.recoverSwitchFailed)
      }
      guard !self.terminating else { return }
      self.finishLaunchingAfterRecovery(recoveryMessage: recoveryMessage)
    }
  }

  @MainActor private func finishLaunchingAfterRecovery(recoveryMessage: String?) {
    let firstPreparedAt = AppSetup.firstPreparationDate(in: config.dataDir)
    AppSetup.start(config: config, startup: loginStartup, writeGate: switchWriteGate, standby: launchSource != .launchd)
    viewer.store.remoteBackend?.refreshContext()
    if let recoveryMessage { viewer.store.remoteBackend?.error = recoveryMessage }
    MainActor.assumeIsolated {
      WindowVisibility.onChange = { [weak self] _ in self?.updateSyncForeground() }
    }
    let source = viewerDataSource
    Task { await source.activateIfLinked() }
    let pairing = remotePairing
    Task { try? await pairing.cleanupExpiredPreparations() }
    hub.flush()
    Task { @MainActor [weak self] in await self?.historyImporter.tick() }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    // 左键弹面板，右键（或按住 control 点）弹菜单。菜单不常驻在 statusItem 上，否则左键也会弹菜单。
    statusMenu.delegate = self
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusClicked(_:))
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    LanguageStore.shared.onResolvedChange = { [weak self] language in
      guard let self, !self.terminating else { return }
      self.viewer.rebuildMenu()
      self.menuNeedsUpdate(self.statusMenu)
      self.widgetPublisher?.languageChanged(to: language)
      self.syncLanguageIfNeeded()
    }
    NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { LanguageStore.shared.refreshSystemLanguage() }
    }
    registerSources()
    syncLanguageIfNeeded()
    // 上次开启录音时崩溃：先关掉录音开关，再启动各数据源。
    if audio.initiallyBlocked { toggles.setEnabled("audio", false) }
    sources.launch(paused: paused)
    updateIcon()
    MainActor.assumeIsolated {
      if config.allowsLocalHub { deviceDiscovery.refreshIfDue(api: api) }
      else { deviceDiscovery.update(nil) }
    }

    timers = [
      Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() },
      Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateAudio() },
      Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        Task { await source.refreshBinding() }
        self?.hub.flush()
        Task { @MainActor [weak self] in
          guard let self, !self.terminating else { return }
          await AppSetup.resumeAfterRecovery(config: self.config, startup: self.loginStartup, writeGate: self.switchWriteGate,
                                             standby: launchSource != .launchd)
        }
        Task { @MainActor [weak self] in await self?.historyImporter.tick() }
      },
      Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.writeStatus() },
      Timer.scheduledTimer(withTimeInterval: config.pluginInterval, repeats: true) { [weak self] _ in self?.plugins.runAll() },
    ]
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.plugins.runAll() }

    let ws = NSWorkspace.shared.notificationCenter
    if let file = WidgetSnapshot.fileURL,
       file.deletingLastPathComponent().deletingLastPathComponent().path == config.dataDir.standardizedFileURL.path,
       let plugins = Bundle.main.builtInPlugInsURL,
       FileManager.default.fileExists(atPath: plugins.appendingPathComponent("TacitWidget.appex").path) {
      MainActor.assumeIsolated {
        widgetPublisher = WidgetSnapshotPublisher(dataSource: viewerDataSource, file: file,
                                                  hubRoute: { [config] in try config.hubRoute() })
        widgetPublisher?.languageChanged(to: LanguageStore.shared.resolved)
      }
      ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.widgetPublisher?.refresh() }
      }
      NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.widgetPublisher?.refresh() }
      }
    }
    readyForTimelineURL = true
    MainActor.assumeIsolated { viewer.store.update.start() }
    if let day = pendingTimelineDay {
      pendingTimelineDay = nil
      MainActor.assumeIsolated { viewer.show(.timelineDay(day)) }
    } else if LaunchWindowPolicy.opensWindow(source: launchSource, loginAt: LoginSession.consoleLoginDate(),
                                             firstPreparedAt: firstPreparedAt) {
      viewer.show()
    }
    ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.updateAudio() }
    ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.closeSegment()
        self?.viewerDataSource.clearMemory()
      }
    }
    DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      self?.closeSegment()
      self?.viewerDataSource.clearMemory()
    }
    DistributedNotificationCenter.default().addObserver(forName: .init(Self.showWindowNotification), object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.viewer.show() }
    }
  }

  /// 把各采集器接到统一的数据源接口上。顺序以 DataSourceCatalog 为准。
  func registerSources() {
    let ocr = ocr
    sources.register(BlockSource("screen") { s in
      s.permissionName = "辅助功能"
      s.permissionCheck = { AXIsProcessTrusted() ? .granted : .denied }
      s.request = { [weak self] in self?.requestAX() }
      s.onEnable = { [weak self] _ in if !AXIsProcessTrusted() { self?.requestAX() } }
      s.onApply = { [weak self] active in if !active { self?.closeSegment() }; self?.updateIcon() }
      s.last = { [weak self] in self?.lastScreen }
    })
    sources.register(BlockSource("ocr") { s in
      s.permissionName = "录屏"
      s.permissionCheck = { ocr.granted ? .granted : .denied }
      s.request = { ocr.requestAccess(); if !ocr.granted { SystemPermissions.openPrivacyPane("Privacy_ScreenCapture") } }
      s.onEnable = { _ in if !ocr.granted { ocr.requestAccess() } }
      s.last = { [weak self] in self?.lastOCRRun }
      s.describe = { [weak self] in self?.enabled("screen") == false ? (L10n.text(zh: "要先打开“屏幕文字”", en: "Turn on Screen activity first"), false) : ("", true) }
    })
    sources.register(BlockSource("audio") { s in
      s.permissionName = "麦克风"
      s.permissionCheck = SystemPermissions.microphone
      s.request = SystemPermissions.requestMicrophone
      // 用户手动打开录音时解除"上次启动崩溃"的保护（与原来的菜单开关一致）；启动时不解除。
      s.onEnable = { [weak self] user in if user { self?.audio.allowManualStart() } }
      s.onApply = { [weak self] _ in self?.updateAudio() }
      s.describe = { [weak self] in
        // 第一行是今天的计数，第二行是麦克风，之后是问题：有问题时先说问题，让列表也标红。
        let lines = self?.audio.status() ?? []
        if let problem = lines.dropFirst(2).first(where: { !$0.hasPrefix("正在") }) { return (problem, false) }
        let line = lines.dropFirst(2).first ?? lines.first ?? ""
        return (line, !["失败", "崩溃", "不可用", "缺少", "跟不上"].contains { line.contains($0) })
      }
    })
    let wechat = wechat
    sources.register(BlockSource("wechat") { s in
      s.permissionName = "录屏"
      s.permissionCheck = { ocr.granted ? .granted : .denied }
      s.request = { ocr.requestAccess(); if !ocr.granted { SystemPermissions.openPrivacyPane("Privacy_ScreenCapture") } }
      s.onEnable = { _ in if !ocr.granted { ocr.requestAccess() } }
      s.last = { wechat.last }
      s.describe = { (wechat.lastSummary, true) }
    })
    plugins.isEnabled = { [toggles] in toggles.isEnabled($0) }
    for name in DataSourceCatalog.plugins.map(\.id) { sources.register(PluginSource(name, scheduler: plugins)) }
    reloadExtensions()
  }

  /// 从 Finder、Spotlight 或 Dock 再次打开 App 时弹出主窗口。
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainActor.assumeIsolated { viewer.show() }; return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let day = urls.lazy.compactMap({ WidgetSnapshot.timelineDate(from: $0) }).first,
          day <= Date() else { return }
    if readyForTimelineURL { MainActor.assumeIsolated { viewer.show(.timelineDay(day)) } }
    else { pendingTimelineDay = day }
  }

  func applicationWillTerminate(_ n: Notification) {
    guard !terminating else { return }
    terminating = true
    CleanQuitMarker.mark(in: config.dataDir)
    MainActor.assumeIsolated {
      widgetPublisher?.stop()
      deviceDiscovery.update(nil)
    }
    viewerDataSource.stop()
    timers.forEach { $0.invalidate() }
    audio.shutdown()
    captureQueue.sync { emit(segmenter.flush()) }
    let deadline = Date().addingTimeInterval(3)
    hub.flush()
    while hub.pendingCount > 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
  }

  // MARK: 屏幕

  var paused: Bool {
    if let p = pausedUntil, p > Date() { return true }
    if pausedUntil != nil { pausedUntil = nil; sources.applyAll(paused: false) }
    return false
  }

  func tick() {
    guard !terminating else { return }
    // 微信对话不依赖屏幕文字和辅助功能：只要开着、微信在前台就截图拆消息。
    if !paused, enabled("wechat"), !IsSecureEventInputEnabled(),
       let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == WeChatCollector.bundleID,
       !CapturePolicy.shouldSkip(bundleID: WeChatCollector.bundleID, window: "") {
      wechat.poll(pid: front.processIdentifier, frame: nil)
    }
    guard !paused, enabled("screen"), AXIsProcessTrusted() else { closeSegment(); updateIcon(); return }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    if idle > segmenter.config.idleLimit { closeSegment(); return }
    // 有密码框处于输入状态（安全输入）时什么都不读。
    if IsSecureEventInputEnabled() {
      captureQueue.async { [self] in stats["skippedSecureInput", default: 0] += 1; emit(segmenter.flush()) }
      return
    }
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
    let pid = app.processIdentifier
    let bundle = app.bundleIdentifier ?? "unknown"
    let name = app.localizedName ?? bundle
    let now = Date()
    lastScreen = now
    let ocrOn = enabled("ocr")
    let keepText = ScreenTextPolicy.keepsText(bundleID: bundle)

    captureQueue.async { [self] in
      if CapturePolicy.shouldSkip(bundleID: bundle, window: "") {
        stats["skippedPolicy", default: 0] += 1
        emit(segmenter.flush()); return
      }
      let snap = ax.snapshot(pid: pid, includeText: keepText)
      let window = snap?.window ?? ""
      if CapturePolicy.shouldSkip(bundleID: bundle, window: window) {
        stats["skippedPolicy", default: 0] += 1
        emit(segmenter.flush()); return
      }
      let o = Observation(time: now, bundleID: bundle, appName: name, window: window, url: snap?.url,
                          lines: snap?.lines ?? [], editable: snap?.editable ?? [:],
                          method: snap == nil ? "none" : "ax")
      stats["ticks", default: 0] += 1
      if let s = snap {
        stats["scanMsTotal", default: 0] += s.ms
        stats["scanMsMax"] = max(stats["scanMsMax"] ?? 0, s.ms)
        if s.truncated { stats["truncated", default: 0] += 1 }
      }
      emit(segmenter.observe(o))

      // 辅助功能几乎读不到正文时用 OCR 兜底，节奏见 OCRSchedule：画面文字没变就逐步放慢。
      let key = o.key
      if ocrOn, keepText, (snap?.chars ?? 0) < 80, ocrSchedule.due(key, now: now), ocr.granted {
        ocrSchedule.started(key, now: now)
        ocr.recognizeLines(pid: pid, frame: snap?.frame) { [self] found, size, ms in
          let lines = found.filter { line in
            !ScreenTextPolicy.isEditableOCRPoint(CGPoint(x: line.midX, y: line.y + line.height / 2),
                                                 window: size, frame: snap?.frame, editableFrames: snap?.editableFrames ?? [])
          }.map(\.text)
          DispatchQueue.main.async { [self] in lastOCRRun = Date() }
          captureQueue.async { [self] in
            stats["ocrRuns", default: 0] += 1
            stats["ocrMsTotal", default: 0] += ms
            stats["ocrMsMax"] = max(stats["ocrMsMax"] ?? 0, ms)
            stats["ocrLines", default: 0] += lines.count
            ocrSchedule.finished(key, lines: lines)
            emit(segmenter.appendIfCurrent(key: key, lines: lines, method: "ocr", time: Date()))
          }
        }
      }
    }
  }

  func closeSegment() { captureQueue.async { [self] in emit(segmenter.flush()) } }

  /// 只在 captureQueue 上调用。
  func emit(_ records: [Record]) {
    guard !records.isEmpty else { return }
    stats["screenRecords", default: 0] += records.count
    hub.enqueue(records)
  }

  // MARK: 录音

  func updateAudio() {
    guard !terminating else { return }
    audio.update(enabled: enabled("audio") && !paused)
  }

  // MARK: 菜单

  /// 屏幕文字停用时不需要辅助功能权限，不显示缺权限。
  var missingAX: Bool { enabled("screen") && !AXIsProcessTrusted() }

  func updateIcon() {
    guard let statusItem else { return }
    let image = StatusIconArt.image(paused ? .paused : (missingAX ? .warning : .recording))
    image.accessibilityDescription = "Tacit"
    statusItem.button?.image = image
  }

  @objc func statusClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    MainActor.assumeIsolated {
      if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
        panel.close()
        statusItem.menu = statusMenu
        sender.performClick(nil)
        statusItem.menu = nil
      } else {
        panel.toggle(from: sender)
      }
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    updateIcon()
    let state: String
    // 和主窗口底部一致：暂停优先，其次缺权限，数据源全关时写“未在记录”。
    if let p = pausedUntil, paused { state = CaptureFooterStatus.title(state: .paused(p), enabledSources: 0) }
    else if missingAX { state = L10n.text(zh: "需要辅助功能权限", en: "Accessibility permission required") }
    else if !sources.statuses().contains(where: { DataSourceCatalog.isVisible($0.id) && $0.enabled }) { state = L10n.text(zh: "未在记录", en: "Not recording") }
    else { state = L10n.text(zh: "正在记录", en: "Recording") }
    menu.addItem(disabled(state))
    let pending = hub.pendingCount
    let queued = L10n.text(zh: "\(pending) 条记录等待保存", en: L10n.Menu.queued(pending))
    if let e = hub.lastError {
      let separator = L10n.text(zh: "，", en: ", ")
      menu.addItem(disabled(L10n.deliveryIssue(e) + separator + queued))
    } else if pending > 0 { menu.addItem(disabled(queued)) }
    let dropped = hub.queue.dropped + hub.outboxStatus.dropped
    if dropped > 0 { menu.addItem(disabled(L10n.count(dropped, one: "Discarded the oldest pending record", other: "Discarded the %@ oldest pending records", zh: "已丢弃 \(dropped) 条最旧的待保存记录"))) }
    menu.addItem(.separator())

    if paused { menu.addItem(item(L10n.Menu.resume, #selector(resume))) }
    else {
      menu.addItem(item(L10n.Menu.pauseHour, #selector(pauseHour)))
      menu.addItem(item(L10n.Menu.pauseTomorrow, #selector(pauseTomorrow)))
    }
    let open = item(L10n.Menu.open, #selector(openHistory)); open.keyEquivalent = "o"
    menu.addItem(open)
    menu.addItem(.separator())

    // 数据源从注册表生成：勾选即开关，缺权限时给授权入口。
    func sourceItems(_ s: DataSourceStatus, into target: NSMenu) {
      var title = s.title
      if s.enabled {
        if s.running { title += L10n.text(zh: "（正在运行）", en: " (running)") }
        else if !s.ok, !s.detail.isEmpty { title += L10n.text(zh: "：", en: ": ") + (s.id == "audio" ? L10n.audioStatus(s.detail) : s.detail) }
        else if let last = s.lastRun { title += L10n.text(zh: "（\(ViewerFormat.clock(last)) 运行过）", en: " (last ran at \(ViewerFormat.clock(last)))") }
      }
      let toggle = item(title, #selector(toggleSource(_:)))
      toggle.representedObject = s.id; toggle.state = s.enabled ? .on : .off
      target.addItem(toggle)
      if s.needsPermission, let name = s.permissionName {
        let grant = item(L10n.text(zh: "    授权\(name)…", en: "    Grant \(L10n.permission(name)) permission…"), #selector(requestSourcePermission(_:)))
        grant.representedObject = s.id; target.addItem(grant)
      }
    }
    let statuses = sources.statuses().filter { DataSourceCatalog.isVisible($0.id) }
    for s in statuses where s.kind == .builtin {
      sourceItems(s, into: menu)
      if s.id == "audio" {
        menu.addItem(microphoneMenu())
        if s.enabled { for line in MicrophoneChoices.statusLines(Array(audio.status().dropFirst())) { menu.addItem(disabled("    " + L10n.audioStatus(line))) } }
      }
    }
    // AI 会话、浏览器和其他数据源放在一起，不另立“插件”子菜单；用户不需要知道哪个是插件。
    if !plugins.available { menu.addItem(disabled(L10n.Menu.installationIncomplete)) }
    for s in statuses where s.kind == .plugin { sourceItems(s, into: menu) }
    let runAll = item(L10n.text(zh: "同步 AI 会话和浏览器", en: "Sync AI sessions and browser activity"), #selector(runPlugins)); runAll.isEnabled = plugins.available
    menu.addItem(runAll)
    menu.addItem(.separator())
    menu.addItem(item(L10n.text(zh: "退出", en: "Quit"), #selector(quit)))
  }

  func microphoneMenu() -> NSMenuItem {
    let microphones = NSMenu()
    let setting = microphoneSetting
    for choice in microphoneChoices(setting: setting) {
      if choice.group != .mode, microphones.items.count == 2 { microphones.addItem(.separator()) }
      let entry = choice.selectable ? item(choice.title, #selector(selectMicrophone(_:))) : disabled(choice.title)
      entry.representedObject = choice.value
      entry.state = choice.value == setting ? .on : .off
      microphones.addItem(entry)
    }
    let microphoneMenu = NSMenuItem(title: "    " + L10n.Menu.microphone, action: nil, keyEquivalent: "")
    microphoneMenu.submenu = microphones
    return microphoneMenu
  }

  var microphoneSetting: String { UserDefaults.standard.string(forKey: "micDevice") ?? "builtin" }
  /// 菜单栏子菜单和设置页选择器共用。
  func microphoneChoices(setting: String) -> [MicrophoneChoice] {
    MicrophoneChoices.list(devices: try? MicrophoneDevices.inputs().map(\.descriptor), setting: setting)
  }

  func item(_ title: String, _ sel: Selector) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; return i
  }
  func disabled(_ title: String) -> NSMenuItem { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }

  @MainActor func prepareBackendAgain(port: Int? = nil) async throws {
    let result: Result<Void, Error> = await withCheckedContinuation { continuation in
      AppSetup.start(config: config, startup: loginStartup, writeGate: switchWriteGate,
                     standby: launchSource != .launchd, trigger: .manualRetry, port: port) {
        continuation.resume(returning: $0)
      }
    }
    hub.flush()
    try result.get()
    await viewer.store.refreshShared()
  }

  @objc func requestAX() {
    guard !AXIsProcessTrusted() else { return }
    let key = "accessibilityPermissionRequested"
    if UserDefaults.standard.bool(forKey: key) {
      SystemPermissions.openPrivacyPane("Privacy_Accessibility")
      return
    }
    UserDefaults.standard.set(true, forKey: key)
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
  }
  @objc func pauseHour() { pause(until: Date().addingTimeInterval(3600)) }
  @objc func pauseTomorrow() {
    let cal = Calendar.current
    pause(until: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!)
  }
  func pause(until: Date) { pausedUntil = until; sources.applyAll(paused: true); updateIcon() }
  @objc func resume() { pausedUntil = nil; sources.applyAll(paused: false); updateIcon() }
  @objc func toggleSource(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    setSource(id, !enabled(id))
  }
  func setSource(_ id: String, _ on: Bool) {
    if on && managingPlugins.contains(id) { return }
    sources.setEnabled(id, on, paused: paused); updateIcon()
  }
  @objc func requestSourcePermission(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    sources.source(id)?.requestPermission()
  }
  @objc func selectMicrophone(_ sender: NSMenuItem) {
    guard let setting = sender.representedObject as? String else { return }
    audio.selectMicrophone(setting)
  }
  @objc func runPlugins() { plugins.run(plugins.plugins.filter(DataSourceCatalog.isVisible), since: nil) }
  @objc func openHistory() { MainActor.assumeIsolated { viewer.show() } }
  @objc func quit() { NSApp.terminate(nil) }

  // MARK: 维护

  /// 立即同步全部、重新导入最近 7 天、导入全部历史。整理启用前的历史由窗口直接向 hub 提交请求。
  func runMaintenance(_ task: MaintenanceTask) {
    guard task != .backfill, jobs[task]?.running != true else { return }
    guard plugins.available else { jobs[task] = .init(running: false, text: "安装不完整，请重新安装 Tacit。"); return }
    let names = plugins.plugins.filter(enabled)
    jobs[task] = .init(running: true, text: task == .syncAll ? L10n.text(zh: "正在同步…", en: "Syncing…") : L10n.text(zh: "正在导入…", en: "Importing…"))
    if task == .syncAll { hub.flush() }
    let api = api
    plugins.run(names, since: PluginImport.since(task)) { [weak self] results in
      let accepted = results.values.reduce(0) { $0 + $1.accepted }
      let failed = results.filter { !$0.value.ok }.keys.sorted().map { DataSourceCatalog.descriptor($0)?.title ?? $0 }
      let summary = "新增 \(accepted.formatted()) 条" + (failed.isEmpty ? "" : "，\(failed.joined(separator: "、"))没有成功")
      Task { @MainActor in
        var text = summary
        // 同步全部之后请常驻的提炼进程立即跑一轮；采集端不自己启动提炼。
        if task == .syncAll {
          // 整理进度由下一行的整理请求状态表达，这里不写“正在整理”，免得完成后还挂着。
          do { try await api.requestDistill(kind: "round") }
          catch {
            let fallback = L10n.text(zh: "整理没能开始，请稍后重试。", en: "Summarizing couldn't start. Try again shortly.")
            text += L10n.text(zh: "，", en: " ") + UserFacingError.message(for: error, fallback: fallback)
          }
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let done = "\(f.string(from: Date())) 完成，" + text
        self?.jobs[task] = .init(running: false, text: done)
      }
    }
  }

  private var statusThrottle = CollectorStatusThrottle()
  private var statusReporting = false

  func writeStatus(forceReport: Bool = false) {
    MainActor.assumeIsolated {
      syncLanguageIfNeeded()
      if config.allowsLocalHub { deviceDiscovery.refreshIfDue(api: api) }
      else { deviceDiscovery.update(nil) }
    }
    let enabledSources = Dictionary(uniqueKeysWithValues: DataSourceCatalog.all.map { ($0.id, enabled($0.id)) })
    captureQueue.async { [self] in
      let nowDate = Date()
      let timeText = LocalTime.iso(nowDate)
      let outbox = hub.outboxStatus
      let hubBusy = hub.hubBusy
      let queuePeak = hub.queuePeak
      let deliveryIssue = hub.deliveryIssue
      let hubError = deliveryIssue.message
      let transcription = enabledSources["audio"] == true ? audio.transcriptionStatus() : nil
      var s: [String: Any] = stats
      s["queue"] = hub.pendingCount; s["dropped"] = hub.queue.dropped
      s["hubBusy"] = hubBusy; s["queuePeak"] = queuePeak
      s["sent"] = hub.sent; s["rejected"] = hub.rejected; s["hubError"] = hubError ?? NSNull()
      s["hubErrorCategory"] = deliveryIssue.category?.rawValue ?? NSNull()
      s["axTrusted"] = AXIsProcessTrusted(); s["ocrEnabled"] = enabledSources["ocr"] ?? false; s["ocrGranted"] = ocr.granted
      s["sources"] = enabledSources
      s["paused"] = pausedUntil != nil; s["plugins"] = plugins.status()
      s["footprintMB"] = Int(footprintMB()); s["cpuSeconds"] = Int(cpuSeconds())
      s["time"] = timeText
      if enabledSources["audio"] == true { s["micQuietLevels"] = audio.microphoneQuietLevels().json }
      CollectorStatus.write(s, transcription: transcription,
                            outbox: outbox, to: config.dataDir.appendingPathComponent("collector-status.json"))

      let report = CollectorStatusReport(
        time: timeText,
        transcription: transcription,
        outbox: outbox,
        hubBusy: hubBusy,
        queuePeak: queuePeak
      )
      let uptime = ProcessInfo.processInfo.systemUptime
      let hasError = hubError != nil
      guard !statusReporting, statusThrottle.shouldSend(report, hasError: hasError, force: forceReport, now: uptime) else { return }
      statusReporting = true
      let deviceSession = self.deviceSession
      nonisolated(unsafe) weak let weakSelf = self
      let gate = switchWriteGate
      Task {
        let sent: Bool
        if (try? gate.begin()) != nil {
          sent = (try? await deviceSession.send(op: "collector.status", body: report)) != nil
          gate.end()
        } else {
          sent = false
        }
        weakSelf?.captureQueue.async {
          guard let self = weakSelf else { return }
          self.statusReporting = false
          if sent { self.statusThrottle.recordSent(report, hasError: hasError, at: ProcessInfo.processInfo.systemUptime) }
        }
      }
    }
  }
}

/// 与活动监视器的"内存"一致；RSS 会把共享库和映射的模型文件算进来，偏高且可被系统回收。
func footprintMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let r = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
  }
  return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func cpuSeconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

/// 进程启动时刻：刚启动的一分钟里后台可能还在准备，查看窗口连不上时先等（HubAPI.startupGrace）。
let appLaunchedAt = Date()

if CommandLine.arguments.contains("--probe-front") { runProbe(); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
  do { try AppIconArt.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
  catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
}

@MainActor private func initializeAppLanguage(_ config: Config) {
  let priorFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: config.dataDir.path)) ?? [])
  let priorDefaults = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
  LanguageStore.shared.initialize(existingInstallation: LanguagePreference.hasExistingInstallation(
    fileNames: priorFiles, defaultsKeys: Set(priorDefaults.keys)))
}

let config = Config.load()
// The source installer prepares the Hub before launching the collector.
if CommandLine.arguments.contains("--initialize-language") {
  MainActor.assumeIsolated { initializeAppLanguage(config) }
  exit(0)
}
guard MainActor.assumeIsolated({ AppSetup.checkPlacement() }) else { exit(0) }
let logFile = config.dataDir.appendingPathComponent("logs/collector.log")
let launchedByAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.hasPrefix("dev.record-anything.") == true
let launchSource: DiagnosticLog.LaunchSource = launchedByAgent || DiagnosticLog.isFile(logFile, on: STDERR_FILENO)
  ? .launchd : Bundle.main.bundleURL.pathExtension == "app" ? .finder : .unknown
do { try DiagnosticLog.redirectIfNeeded(to: logFile) }
catch { DiagnosticLog.shared.record(.collectorLogOpenFailed) }
DiagnosticLog.installUncaughtExceptionHandler()

// 已经有一个采集端在跑时：访达打开且满足启动窗口规则时，请运行中的实例拿出窗口。
// launchd 拉起的留下待命，正在跑的那份崩溃时接手，正常退出时跟着退出（退出码 0，launchd 不再拉起）。
let lockPath = config.dataDir.appendingPathComponent("collector.lock").path
var instanceLock = InstanceLock.acquire(path: lockPath)
if case .held = instanceLock {
  guard launchedByAgent else {
    if LaunchWindowPolicy.opensWindow(source: launchSource, loginAt: LoginSession.consoleLoginDate(),
                                      firstPreparedAt: AppSetup.firstPreparationDate(in: config.dataDir)) {
      DistributedNotificationCenter.default().postNotificationName(.init(AppDelegate.showWindowNotification), object: nil,
                                                                    userInfo: nil, deliverImmediately: true)
    }
    exit(0)
  }
  guard let lock = InstanceLock.wait(path: lockPath), !CleanQuitMarker.isMarked(in: config.dataDir) else { exit(0) }
  instanceLock = .acquired(lock)
}
MainActor.assumeIsolated { initializeAppLanguage(config) }
CleanQuitMarker.clear(in: config.dataDir)
DiagnosticLog.shared.record(.started(DiagnosticBuild(), launchSource))

Phosphor.register()
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// MARK: 主窗口读取采集状态

extension AppDelegate: CaptureControlling {
  func reloadExtensions() {
    let installed = plugins.installedExtensions()
    for source in sources.sources where source.descriptor.id.hasPrefix("ext-") {
      if !installed.contains(where: { $0.id == source.descriptor.id && $0.manifest.name == source.descriptor.title }) {
        sources.unregister(source.descriptor.id)
      }
    }
    for plugin in installed where sources.source(plugin.id) == nil {
      let source = PluginSource(plugin, scheduler: plugins)
      sources.register(source)
      source.apply(active: !paused && enabled(plugin.id))
    }
  }
  @MainActor func pluginCommand(_ request: PluginRequest) async throws -> PluginResponse {
    // 管理和采集共用串行队列：先停用，再等待已运行的进程退出，避免更新/删除时还在写记录。
    let managed = ["install", "uninstall"].contains(request.action) ? request.id : nil
    if let id = managed { managingPlugins.insert(id); setSource(id, false) }
    defer { if let id = managed { managingPlugins.remove(id) } }
    let result = try await plugins.manage(request)
    if result.error == nil && ["install", "uninstall"].contains(request.action) {
      if let id = result.plugin?.id { toggles.setEnabled(id, false) }
      reloadExtensions()
    }
    return result
  }

  func captureSnapshot() -> CaptureSnapshot {
    var c = CaptureSnapshot()
    if missingAX { c.state = .noPermission } else if let p = pausedUntil, paused { c.state = .paused(p) }
    c.queue = hub.pendingCount
    c.sent = hub.sent
    c.hubError = hub.lastError
    c.sources = sources.statuses()
    c.audio = enabled("audio") ? audio.status() : []
    c.microphone = microphoneSetting
    c.microphones = microphoneChoices(setting: c.microphone)
    c.pluginsAvailable = plugins.available
    c.jobs = jobs
    return c
  }

  func perform(_ action: CaptureAction) {
    switch action {
    case .pauseHour: pauseHour()
    case .pauseTomorrow: pauseTomorrow()
    case .resume: resume()
    case .requestAX: requestAX()
    case .setSource(let id, let on): setSource(id, on)
    case .requestPermission(let id): sources.source(id)?.requestPermission()
    case .runSource(let id): sources.source(id)?.runNow()
    case .maintenance(let task): runMaintenance(task)
    case .selectMicrophone(let setting): audio.selectMicrophone(setting)
    }
  }
}
