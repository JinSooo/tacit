import Foundation

public extension L10n {
  enum Settings {
    // MARK: - General, navigation, and shared controls

    public static var general: String { L10n.text(zh: "通用", en: "General") }
    public static var sources: String { L10n.text(zh: "数据源", en: "Sources") }
    public static var aiModels: String { L10n.text(zh: "AI 模型", en: "AI models") }
    public static var aiTools: String { L10n.text(zh: "AI 工具", en: "AI tools") }
    public static var backendAndConnection: String { L10n.text(zh: "后台与连接", en: "Background service and connection") }
    public static var privacy: String { L10n.text(zh: "隐私", en: "Privacy") }
    public static var maintenance: String { L10n.text(zh: "维护", en: "Maintenance") }
    public static var settings: String { L10n.text(zh: "设置", en: "Settings") }
    public static var agentDirectNotice: String { L10n.text(zh: "连接 AI 工具需要直连远端后台。", en: "Connect directly to the remote background service to manage AI tools.") }
    public static var openBackendSettings: String { L10n.text(zh: "前往后台与连接", en: "Open background service settings") }
    public static var about: String { L10n.text(zh: "关于", en: "About") }
    public static var developmentBuild: String { L10n.text(zh: "开发版", en: "Development build") }
    public static var build: String { L10n.text(zh: "构建", en: "Build") }
    public static var localBuild: String { L10n.text(zh: "本地", en: "Local") }
    public static var startAtLogin: String { L10n.text(zh: "登录后自动启动", en: "Start at login") }
    public static var mixedStartup: String { L10n.text(zh: "部分启动项的设置不一致，重新打开这个开关可统一。", en: "Turn this on again to apply the same setting to all startup items.") }
    public static var startupIncomplete: String { L10n.text(zh: "启动配置不完整，请重新安装应用。", en: "Reinstall Tacit to complete the startup configuration.") }
    public static var startup: String { L10n.text(zh: "启动与运行", en: "Startup") }
    public static var startupNote: String { L10n.text(zh: "登录这台 Mac 后在菜单栏运行，并启动保存与整理服务。关闭后本次继续运行，下次需手动打开应用。关闭主窗口不会停止记录。", en: "Tacit starts recording and summarizing when you log in if this is on, and keeps recording when you close the main window.") }
    public static var sessionContextLimit: String { L10n.text(zh: "自动带入的长度上限", en: "Session context limit") }
    public static var restoreDefaults: String { L10n.text(zh: "恢复默认", en: "Restore defaults") }
    public static var revertChanges: String { L10n.text(zh: "撤销修改", en: "Revert changes") }
    public static var saving: String { L10n.text(zh: "正在保存…", en: "Saving…") }
    public static var save: String { L10n.text(zh: "保存", en: "Save") }
    public static var retry: String { L10n.text(zh: "重试", en: "Retry") }
    public static var sessionContext: String { L10n.text(zh: "自动带入项目进展", en: "Session context") }
    public static var sessionContextNote: String { L10n.text(zh: "新会话按这个长度带入当前项目的进展，超出时先舍弃较旧的事项；更早、更细的内容 AI 会自己查。", en: "New sessions get the latest project progress within this limit, and AI tools can look up older details.") }
    public static var localPortNote: String { L10n.text(zh: "端口只在冲突时改，保存后后台服务会自动重启，记录会接着保存。", en: "Change the port if it conflicts with another service. Recording continues while the background service restarts.") }
    public static var currentBackend: String { L10n.text(zh: "当前后台", en: "Current background service") }
    public static var thisMac: String { L10n.text(zh: "这台 Mac", en: "This Mac") }
    public static var backgroundService: String { L10n.text(zh: "后台服务", en: "Background service") }
    public static var address: String { L10n.text(zh: "地址", en: "Address") }
    public static var port: String { L10n.text(zh: "端口", en: "Port") }
    public static var restarting: String { L10n.text(zh: "正在重启…", en: "Restarting…") }
    public static var saveAndRestart: String { L10n.text(zh: "保存并重启", en: "Save and restart") }
    public static var invalidPort: String { L10n.text(zh: "端口必须是 1024–65535 之间的整数。", en: "Enter a whole number from 1024 to 65535.") }
    public static var webView: String { L10n.text(zh: "详细状态", en: "Web view") }
    public static var detailedStatus: String { L10n.text(zh: "详细状态", en: "Detailed status") }
    public static var openInBrowser: String { L10n.text(zh: "在浏览器中打开", en: "Open in browser") }
    public static var backendNotReady: String { L10n.text(zh: "后台服务尚未准备好，请稍后重试。", en: "The background service is starting. Try again shortly.") }
    public static var waitingToSave: String { L10n.text(zh: "等待保存", en: "Waiting to save") }
    public static var status: String { L10n.text(zh: "状态", en: "Status") }
    public static var checking: String { L10n.text(zh: "正在检查…", en: "Checking…") }
    public static var portLocked: String { L10n.text(zh: "端口由环境变量 RA_PORT 固定，这里不能改。", en: "The RA_PORT environment variable sets the port.") }
    public static var backendRestarting: String { L10n.text(zh: "后台服务正在重启…", en: "Restarting the background service…") }
    public static var portUpdated: String { L10n.text(zh: "端口已更新。", en: "Port updated.") }
    public static var backendRestartTimeout: String { L10n.text(zh: "30 秒内没连上后台服务，可以在维护里复制诊断信息排查。", en: "The background service didn't respond within 30 seconds. Copy diagnostics from Maintenance to investigate.") }
    public static var pauseRecording: String { L10n.text(zh: "暂停记录", en: "Pause recording") }
    public static var resumeRecording: String { L10n.text(zh: "继续记录", en: "Resume recording") }
    public static var pauseOneHour: String { L10n.text(zh: "暂停 1 小时", en: "Pause for 1 hour") }
    public static var pauseUntilTomorrow: String { L10n.text(zh: "暂停到明天", en: "Pause until tomorrow") }
    public static var passwordsAndKeys: String { L10n.text(zh: "密码和密钥", en: "Passwords and keys") }
    public static var redactionRule: String { L10n.text(zh: "保存前换成 [已脱敏]，原文不写进磁盘", en: "Replaced with [redacted] before saving") }
    public static var privateContent: String { L10n.text(zh: "标为私密的内容", en: "Private content") }
    public static var privateDefaultRule: String { L10n.text(zh: "不交给 AI 整理，也不自动带入", en: "Excluded from AI summaries and session context") }
    public static var deletedRecords: String { L10n.text(zh: "删除的记录", en: "Deleted records") }
    public static var deletionRule: String { L10n.text(zh: "在线的设备马上清掉，离线的下次连上时清掉", en: "Removed from online devices now and offline devices when they reconnect") }
    public static var handlingRules: String { L10n.text(zh: "处理规则", en: "Data handling") }
    public static var privateSearchNote: String { L10n.text(zh: "已连接的 AI 工具主动查询时仍能读到私密记录，每次查询都记在运行记录里。", en: "Connected AI tools can search private records, and every query appears in the Run log.") }
    public static var runLog: String { L10n.text(zh: "运行记录", en: "Run log") }
    public static var open: String { L10n.text(zh: "打开", en: "Open") }
    public static var missingSources: String { L10n.text(zh: "安装不完整，AI 会话和浏览器等数据源暂时不能运行。重新安装 Tacit 就能修好。", en: "Reinstall Tacit to restore sources such as AI sessions and browser history.") }
    public static var sync: String { L10n.text(zh: "同步", en: "Sync") }
    public static var syncAllWhat: String { L10n.text(zh: "把还没保存的记录送到后台服务，让开着的数据源读一次新内容，再整理一轮。", en: "Send pending records to the background service, read new content from enabled sources, and summarize.") }
    public static var syncAllDetail: String { L10n.text(zh: "读取所有开着的数据源，已有的不会重复，随后整理一轮。", en: "Reads all enabled sources, skips duplicates, and summarizes afterward.") }
    public static var importRecords: String { L10n.text(zh: "导入", en: "Import") }
    public static var reimportWhat: String { L10n.text(zh: "从 7 天前重新读一遍 AI 会话和浏览器，补上漏掉的记录。", en: "Reimport the last 7 days of AI sessions and browser history to fill gaps.") }
    public static var reimportDetail: String { L10n.text(zh: "读取 AI 会话、浏览器，已有的不会重复，按平常的节奏整理。", en: "Reads AI sessions and browser history, skips duplicates, and summarizes on the usual schedule.") }
    public static var importAllWhat: String { L10n.text(zh: "导入能读到的全部 AI 会话和浏览器历史，可能要几分钟，导入后能搜到、AI 工具也能查到。", en: "Import all available AI sessions and browser history so you and your AI tools can search them.") }
    public static var importAllDetail: String { L10n.text(zh: "已有的不会重复，不自动整理，需要时用下面的“整理启用前的历史”。", en: "Skips duplicates. Use “Summarize earlier history” below when you want summaries.") }
    public static var summarize: String { L10n.text(zh: "整理", en: "Summarize") }
    public static var dateRange: String { L10n.text(zh: "日期范围", en: "Date range") }
    public static var from: String { L10n.text(zh: "从", en: "From") }
    public static var to: String { L10n.text(zh: "至", en: "To") }
    public static var backfillDirectNotice: String { L10n.text(zh: "整理远端后台的历史记录需要直连。", en: "Connect directly to the remote background service to summarize earlier history.") }
    public static var backfillWhat: String { L10n.text(zh: "把所选日期里还没整理的历史交给 AI，整理出事项、项目和每日时间线。", en: "Use AI to summarize records from the selected dates into tasks, projects, and daily timelines.") }
    public static var backfillDetail: String { L10n.text(zh: "读已有记录，不重新采集；整理过的不重复；会调用 AI 模型。", en: "Reads existing records, skips previous summaries, and uses the configured AI models.") }
    public static var loading: String { L10n.text(zh: "正在读取…", en: "Loading…") }
    public static var copied: String { L10n.text(zh: "已复制", en: "Copied") }
    public static var copy: String { L10n.text(zh: "复制", en: "Copy") }
    public static var showInFinder: String { L10n.text(zh: "在访达中显示", en: "Show in Finder") }
    public static var dataAndBackups: String { L10n.text(zh: "数据与备份", en: "Data and backups") }
    public static var keyBackupNote: String { L10n.text(zh: "只含密钥，不含记录和录音；换电脑时要和数据目录一起带走才能打开。", en: "The backup contains keys only. Bring it with the data folder when you move to another Mac.") }
    public static var inProgress: String { L10n.text(zh: "进行中…", en: "In progress…") }
    public static var reinstallTacit: String { L10n.text(zh: "安装不完整，请重新安装 Tacit 再试。", en: "Reinstall Tacit and try again.") }
    public static var keyBackupFailed: String { L10n.text(zh: "有密钥没读到，备份不完整，所以没有复制；可以复制上面的诊断信息排查。", en: "Some keys couldn't be read, so the backup was cancelled. Copy diagnostics above to investigate.") }
    public static var contextSaved: String { L10n.text(zh: "已保存，下次带入项目进展时生效。", en: "Saved. Applies the next time session context is added.") }
    public static var summarySettingsSaved: String { L10n.text(zh: "已保存，下次整理时生效。", en: "Saved. Applies to the next summary.") }

    // MARK: - Sources and recording

    public static var allSources: String { L10n.text(zh: "全部数据源", en: "All sources") }
    public static var viewDetails: String { L10n.text(zh: "查看详情", en: "View details") }
    public static var screenSourceNote: String { L10n.text(zh: "正在用的窗口：应用、标题、网址，以及窗口里新出现的文字。", en: "Records the app, title, URL, and new text in the active window.") }
    public static var screenTextSourceNote: String { L10n.text(zh: "读不到文字的应用在本机截图识别，截图只在内存里，识别完就丢掉。", en: "Recognizes on-screen text locally and discards each screenshot after use.") }
    public static var audioSourceNote: String { L10n.text(zh: "有你说话的对话在本机转成文字，原始音频加密留在本机。", en: "Transcribes conversations you took part in locally and keeps the encrypted audio on this Mac.") }
    public static var wechatSourceNote: String { L10n.text(zh: "微信在最前面时按会话记下看得到的消息；打开后“截图识字”不再重复读微信。", en: "Records visible messages by conversation when WeChat is active and excludes them from Screen text when enabled.") }
    public static var aiSessionSourceNote: String { L10n.text(zh: "记录 AI 会话里你说的话和 AI 工具的最终回复。", en: "Records your messages and the AI tool’s final replies.") }
    public static var browserSourceNote: String { L10n.text(zh: "Chrome、Arc、Safari 等浏览器的访问记录。", en: "Records visits in Chrome, Arc, Safari, and other supported browsers.") }
    public static var grantPermission: String { L10n.text(zh: "授权…", en: "Grant permission…") }
    public static var lastRun: String { L10n.text(zh: "上次运行", en: "Last run") }
    public static var running: String { L10n.text(zh: "正在运行…", en: "Running…") }
    public static var neverRun: String { L10n.text(zh: "还没运行过", en: "Never run") }
    public static var run: String { L10n.text(zh: "运行", en: "Run") }
    public static var permissionGranted: String { L10n.text(zh: "已授权", en: "Granted") }
    public static var permissionMissing: String { L10n.text(zh: "未授权", en: "Not granted") }
    public static var inputDevice: String { L10n.text(zh: "输入设备", en: "Input device") }
    public static var microphone: String { L10n.text(zh: "麦克风", en: "Microphone") }
    public static var originalAudioRetention: String { L10n.text(zh: "原始音频保留", en: "Original audio retention") }
    public static var clearAfterDays: String { L10n.text(zh: "按天清除", en: "Clear after a set number of days") }
    public static var neverClearAutomatically: String { L10n.text(zh: "不自动清除", en: "Never clear automatically") }
    public static var retentionDays: String { L10n.text(zh: "保留天数", en: "Days to keep") }
    public static var audioRetention: String { L10n.text(zh: "音频保留", en: "Audio retention") }
    public static var audioRetentionNote: String { L10n.text(zh: "只清原始音频，转好的文字一直保留。", en: "Transcripts are kept when original audio is cleared.") }
    public static var deleteAudio: String { L10n.text(zh: "删除全部原始音频…", en: "Delete all original audio…") }
    public static var confirmDeleteAudio: String { L10n.text(zh: "删除全部原始音频？", en: "Delete all original audio?") }
    public static var delete: String { L10n.text(zh: "删除", en: "Delete") }
    public static var cancel: String { L10n.text(zh: "取消", en: "Cancel") }
    public static var deleteAudioNote: String { L10n.text(zh: "删除后不能恢复。转好的文字会保留，还没转成文字的对话会丢失；正在录的这一段不受影响。", en: "Deleting original audio permanently removes conversations that have yet to be transcribed. Transcripts and the current recording are kept.") }
    public static var audioDeletionScheduled: String { L10n.text(zh: "已安排删除，各设备下次同步时清掉原始音频。", en: "Devices will delete original audio the next time they sync.") }

    // MARK: - AI tools and setup checklist

    public static var disconnecting: String { L10n.text(zh: "正在断开…", en: "Disconnecting…") }
    public static var connecting: String { L10n.text(zh: "正在连接…", en: "Connecting…") }
    public static var disconnect: String { L10n.text(zh: "断开", en: "Disconnect") }
    public static var connect: String { L10n.text(zh: "连接", en: "Connect") }
    public static var toolsNote: String { L10n.text(zh: "接入后，AI 工具可以查询你的历史记录，每次读取都记在运行记录里。", en: "Connected AI tools can search your history, with each read listed in the Run log.") }
    public static var toolNotInstalled: String { L10n.text(zh: "这台 Mac 上没有安装", en: "Not installed on this Mac") }
    public static var toolPartiallyConnected: String { L10n.text(zh: "连接不完整，请重新连接。", en: "Reconnect to finish setting up this AI tool.") }
    public static var toolConnected: String { L10n.text(zh: "已接入", en: "Connected") }
    public static var otherAgentTools: String { L10n.text(zh: "其他工具", en: "Other tools") }
    public static var manualToolPartial: String { L10n.text(zh: "接入未完成", en: "Setup incomplete") }
    public static var agentInstructions: String { L10n.text(zh: "接入方法", en: "How to connect") }
    public static func agentInstructionsFor(_ tool: String) -> String {
      L10n.text(zh: "在 \(tool) 里接入 Tacit", en: "Connect Tacit in \(tool)")
    }
    public static func reopenAgent(_ tool: String) -> String {
      L10n.text(zh: "改完重开 \(tool) 生效。", en: "Reopen \(tool) to apply the changes.")
    }
    public static func agentConfigInstruction(_ file: String, section: String?, action: String, sessionStart: Bool) -> String {
      let zh: String
      let en: String
      switch (action, section) {
      case ("create", _):
        zh = "新建 \(file) 并填入以下内容"
        en = "Create \(file) with the configuration below"
      case ("replace", let section?):
        zh = "在 \(file) 中替换 \(section)"
        en = "Replace \(section) in \(file)"
      case ("add", let section?):
        zh = "加到 \(file) 的 \(section) 里"
        en = "Add this to \(section) in \(file)"
      case ("merge", _):
        zh = "将以下设置合并到 \(file)"
        en = "Merge these settings into \(file)"
      default:
        zh = "加到 \(file) 的最外层"
        en = "Add this at the top level of \(file)"
      }
      return L10n.text(
        zh: zh + (sessionStart ? "，新会话开头会自动带上项目近况。" : "。"),
        en: en + (sessionStart ? " to include project context at the start of new sessions." : ".")
      )
    }
    public static var setupChecklist: String { L10n.text(zh: "还差几步", en: "Setup checklist") }
    public static var expanded: String { L10n.text(zh: "已展开", en: "Expanded") }
    public static var collapsed: String { L10n.text(zh: "已折叠", en: "Collapsed") }
    public static var grantSystemPermissions: String { L10n.text(zh: "打开系统权限", en: "Grant system permissions") }
    public static var setupModels: String { L10n.text(zh: "让 AI 整理你的记录", en: "Set up summaries for your records") }
    public static var checkModels: String { L10n.text(zh: "检查 AI 模型…", en: "Check AI models…") }
    public static var setupTools: String { L10n.text(zh: "连接你使用的 AI 工具", en: "Connect your AI tools") }
    public static var connectEllipsis: String { L10n.text(zh: "连接…", en: "Connect…") }
    public static var toolSearchNote: String { L10n.text(zh: "连接后，可以让 AI 查询你最近在做什么。", en: "Connected AI tools can look up what you've been working on.") }
    public static var setupToolInstallNote: String { L10n.text(zh: "在这台 Mac 上安装并登录支持的 AI 工具后，就可以连接。", en: "Install a supported AI tool on this Mac and sign in to connect it.") }
    public static var firstSummaryNote: String { L10n.text(zh: "第一次整理会在 15 分钟内完成。", en: "The first summary will be ready within 15 minutes.") }

    // MARK: - Diagnostics

    public static var openLogsFolder: String { L10n.text(zh: "打开日志文件夹", en: "Open log folder") }
    public static var previewAndCopy: String { L10n.text(zh: "预览并复制…", en: "Preview and copy…") }
    public static var diagnostics: String { L10n.text(zh: "诊断信息", en: "Diagnostics") }
    public static var diagnosticsNote: String { L10n.text(zh: "包含版本、运行状态和日志事件，不包含记录内容。", en: "Includes version, runtime status, and log events.") }
    public static var diagnosticsPreview: String { L10n.text(zh: "诊断信息预览", en: "Diagnostics preview") }
    public static var loadingDiagnostics: String { L10n.text(zh: "正在读取诊断信息", en: "Loading diagnostics") }
    public static var close: String { L10n.text(zh: "关闭", en: "Close") }
    public static var unknownArchitecture: String { L10n.text(zh: "未知架构", en: "Unknown architecture") }

    // MARK: - AI models

    public static var localOllama: String { L10n.text(zh: "本机 Ollama", en: "Local Ollama") }
    public static var localLMStudio: String { L10n.text(zh: "本机 LM Studio", en: "Local LM Studio") }
    public static var remoteModelRequired: String { L10n.text(zh: "请填写远端后台使用的 API 模型。", en: "Choose an API model for the remote background service.") }
    public static var invalidModelSettings: String { L10n.text(zh: "模型设置有问题，整理会失败，检查后保存一次就能修好。", en: "Check and save your model settings to resume summaries.") }
    public static var deleteAPIKeyQuestion: String { L10n.text(zh: "删除 API key？", en: "Delete API key?") }
    public static var unusedAPIKey: String { L10n.text(zh: "现在没有模型在用它。", en: "No models currently use this key.") }
    public static var apiKeyDeletionNote: String { L10n.text(zh: "用这个提供商的模型会连不上，直到重新设置 API key。", en: "Models from this provider need a new API key to connect again.") }
    public static var summarizeTimeline: String { L10n.text(zh: "整理时间线", en: "Summarize timeline") }
    public static var afterActivity: String { L10n.text(zh: "每段结束后", en: "After each activity") }
    public static var hourly: String { L10n.text(zh: "每小时", en: "Hourly") }
    public static var nightly: String { L10n.text(zh: "只在晚上", en: "Only at night") }
    public static var timelinePolishNote: String { L10n.text(zh: "越晚整理用量越少，草稿始终实时出现。", en: "Summarizing later uses fewer tokens, and drafts still appear as you go.") }
    public static var dayOverview: String { L10n.text(zh: "当天概述", en: "Day overview") }
    public static var everyThreeHours: String { L10n.text(zh: "每 3 小时", en: "Every 3 hours") }
    public static var dailyUsageLimit: String { L10n.text(zh: "每天用量上限", en: "Daily token limit") }
    public static var unlimited: String { L10n.text(zh: "不限", en: "Unlimited") }
    public static var custom: String { L10n.text(zh: "自定义", en: "Custom") }
    public static var dailyMaximum: String { L10n.text(zh: "每天最多", en: "Daily maximum") }
    public static var limitExample: String { L10n.text(zh: "例如 50", en: "For example, 50") }
    public static var tenThousandTokens: String { L10n.text(zh: "万 token", en: "× 10,000 tokens") }
    public static var dailyUsageLimitNote: String { L10n.text(zh: "达到后当天暂停整理，明天 0 点恢复，草稿照常出现。", en: "Summaries pause at the limit and resume at midnight, while drafts keep appearing.") }
    public static var timelineSummarySettings: String { L10n.text(zh: "时间线整理", en: "Timeline summaries") }
    public static var viewDetailedUsage: String { L10n.text(zh: "查看详细用量", en: "View usage details") }
    public static var provider: String { L10n.text(zh: "提供商", en: "Provider") }
    public static var selectProvider: String { L10n.text(zh: "选择提供商", en: "Select a provider") }
    public static var model: String { L10n.text(zh: "模型", en: "Model") }
    public static var localModels: String { L10n.text(zh: "本机模型", en: "Local models") }
    public static var loadingLocalModels: String { L10n.text(zh: "正在读取本机模型…", en: "Loading local models…") }
    public static var noLocalModels: String { L10n.text(zh: "服务已连接，但没有可用模型，请先在模型服务中下载或加载模型。", en: "Download or load a model in your local model service.") }
    public static var refreshModels: String { L10n.text(zh: "刷新模型", en: "Refresh models") }
    public static var thinkingEffort: String { L10n.text(zh: "思考强度", en: "Thinking effort") }
    public static var modelDefault: String { L10n.text(zh: "跟随模型", en: "Model default") }
    public static var off: String { L10n.text(zh: "关闭", en: "Off") }
    public static var low: String { L10n.text(zh: "低", en: "Low") }
    public static var medium: String { L10n.text(zh: "中", en: "Medium") }
    public static var high: String { L10n.text(zh: "高", en: "High") }
    public static var summaryModel: String { L10n.text(zh: "整理模型", en: "Summary model") }
    public static var sharedModelNote: String { L10n.text(zh: "实时整理、每小时汇总和每日时间线都用它。", en: "Live, Hourly roundup, and Daily timeline all use this model.") }
    public static var separateModels: String { L10n.text(zh: "按任务分别设置", en: "Set up each task separately") }
    public static var shareModel: String { L10n.text(zh: "全部任务都用这一组", en: "Use this setup for all tasks") }
    public static var remoteModelAddressNote: String { L10n.text(zh: "须能从远端后台访问；填本机地址时，指的是远端后台那台机器。", en: "The remote background service must be able to reach this address. A local address refers to the remote machine itself.") }
    public static var localModelAddressNote: String { L10n.text(zh: "本机地址也可能转发到云端，实际运行位置由模型服务决定。", en: "Your local model service may forward requests to a cloud service.") }
    public static var modelAddressNote: String { L10n.text(zh: "整理时，记录会发到这个地址。", en: "Records are sent to this address for summarization.") }
    public static var testing: String { L10n.text(zh: "正在测试…", en: "Testing…") }
    public static var testConnection: String { L10n.text(zh: "测试连接", en: "Test connection") }
    public static var latestSummary: String { L10n.text(zh: "最近整理", en: "Last summary") }
    public static var currentlyUnavailable: String { L10n.text(zh: "暂时读不到", en: "Unavailable") }
    public static var awaitingFirstSummary: String { L10n.text(zh: "等待首次完成", en: "Waiting for the first summary") }
    public static var connectionOK: String { L10n.text(zh: "连接正常。", en: "Connection successful.") }
    public static var connectionNeedsSave: String { L10n.text(zh: "连接正常，保存后生效", en: "Connection successful. Save to apply.") }
    public static var viewModelFailure: String { L10n.text(zh: "查看原因", en: "View reason") }
    public static var modelFailureLocalNote: String { L10n.text(zh: "只在这台 Mac 上显示", en: "Shown only on this Mac") }
    public static var connectionTestNote: String { L10n.text(zh: "正在连接，最长等 1 分钟…", en: "Connecting. This can take up to a minute…") }
    public static var configured: String { L10n.text(zh: "已设置", en: "Set") }
    public static var notConfigured: String { L10n.text(zh: "未设置", en: "Not set") }
    public static var apiKeyStatusUnavailable: String { L10n.text(zh: "读不到 API key 状态", en: "API key status unavailable") }
    public static var keychainUnavailable: String { L10n.text(zh: "读不到钥匙串", en: "Can't read the Keychain") }
    public static var replaceEllipsis: String { L10n.text(zh: "更换…", en: "Replace…") }
    public static var setEllipsis: String { L10n.text(zh: "设置…", en: "Set…") }
    public static var deleteEllipsis: String { L10n.text(zh: "删除…", en: "Delete…") }
    public static var otherAPIKeys: String { L10n.text(zh: "其他已保存的 API key", en: "Other saved API keys") }
    public static var anthropicModelExample: String { L10n.text(zh: "例如 claude-haiku-5-5", en: "For example, claude-haiku-5-5") }
    public static var codexModelExample: String { L10n.text(zh: "例如 gpt-6-luna", en: "For example, gpt-6-luna") }
    public static var claudeModelExample: String { L10n.text(zh: "例如 claude-sonnet-5-5", en: "For example, claude-sonnet-5-5") }
    public static var modelName: String { L10n.text(zh: "模型名", en: "Model name") }
    public static var invalidTokenLimit: String { L10n.text(zh: "用量上限请填大于 0 的数字，最多四位小数。", en: "Enter a limit greater than 0 with up to four decimal places.") }
    public static var connectionFailed: String { L10n.text(zh: "连接失败。", en: "Couldn't connect.") }
    public static var remoteKeyNote: String { L10n.text(zh: "API key 加密保存在远端后台，设置后不再显示；同一个提供商共用一个。", en: "The remote background service stores the key encrypted and uses it for all models from this provider.") }
    public static var localKeyNote: String { L10n.text(zh: "存在这台 Mac 的钥匙串里，设置后不再显示；同一个提供商共用一个。", en: "The key is stored in this Mac's Keychain and shared by all models from this provider.") }

    // MARK: - Source extensions

    public static var installSource: String { L10n.text(zh: "安装数据源", en: "Install source") }
    public static var updateSource: String { L10n.text(zh: "更新数据源", en: "Update source") }
    public static var pluginPermissionNote: String { L10n.text(zh: "安装后默认停用。插件只能读取下列获准范围，不能联网、修改文件或启动其他程序；记录入库前仍会过滤黑名单与密钥。", en: "Plugins start disabled and can only read approved data. Tacit still filters blocked content and secrets before saving.") }
    public static var chooseAgain: String { L10n.text(zh: "重新选择", en: "Choose again") }
    public static var confirmPluginUpdate: String { L10n.text(zh: "确认更新并停用", en: "Confirm update and disable") }
    public static var confirmPluginInstall: String { L10n.text(zh: "确认权限并安装", en: "Confirm permissions and install") }
    public static var pluginManifestNote: String { L10n.text(zh: "选择带有 plugin.json 清单的目录，或填写 Git 仓库地址。这里只读取清单，不会运行插件。", en: "Choose a folder containing plugin.json or enter a Git repository URL to preview its manifest.") }
    public static var pluginLocation: String { L10n.text(zh: "本地目录或 https://、ssh:// Git 地址", en: "Local folder or Git URL using HTTPS or SSH") }
    public static var chooseLocalFolder: String { L10n.text(zh: "选择本地目录…", en: "Choose local folder…") }
    public static var previewPermissions: String { L10n.text(zh: "预览权限与配置", en: "Preview permissions and configuration") }
    public static var processing: String { L10n.text(zh: "正在处理…", en: "Processing…") }
    public static var pluginPurpose: String { L10n.text(zh: "插件用途说明", en: "Plugin purpose") }
    public static var noExtraPermissions: String { L10n.text(zh: "未声明额外权限", en: "No extra permissions declared") }
    public static var allowedReadScope: String { L10n.text(zh: "实际允许读取", en: "Allowed read access") }
    public static var legacyPluginNote: String { L10n.text(zh: "仅插件自身代码与上次读取进度。旧插件需要更新读取范围声明后才能读取其他文件。", en: "Access is limited to plugin code and its saved progress until the plugin declares what else it needs to read.") }
    public static var unspecified: String { L10n.text(zh: "尚未指定", en: "Unspecified") }
    public static var requiredSuffix: String { L10n.text(zh: "（必填）", en: " (required)") }
    public static var invalidNumber: String { L10n.text(zh: "请输入有效数字", en: "Enter a valid number") }
    public static var pluginInfo: String { L10n.text(zh: "插件信息", en: "Plugin information") }
    public static var version: String { L10n.text(zh: "版本", en: "Version") }
    public static var installOrigin: String { L10n.text(zh: "安装来源", en: "Install source") }
    public static var pinnedRevision: String { L10n.text(zh: "固定提交", en: "Pinned commit") }
    public static var openSystemPrivacy: String { L10n.text(zh: "打开系统隐私设置…", en: "Open system privacy settings…") }
    public static var pluginScopeNote: String { L10n.text(zh: "只能读取获准文件与目录；不能联网、修改文件或启动其他程序。修改读取范围后确认并保存才会生效。系统隐私权限仍需单独授权。", en: "Plugins can read approved files and folders after you confirm the scope and grant any required system permissions.") }
    public static var configuration: String { L10n.text(zh: "配置", en: "Configuration") }
    public static var confirmScopeSave: String { L10n.text(zh: "确认范围并保存", en: "Confirm scope and save") }
    public static var manage: String { L10n.text(zh: "管理", en: "Manage") }
    public static var checkPluginUpdate: String { L10n.text(zh: "检查并更新…", en: "Check for updates…") }
    public static var uninstall: String { L10n.text(zh: "卸载…", en: "Uninstall…") }
    public static var uninstallKeepRecords: String { L10n.text(zh: "卸载，保留记录", en: "Uninstall and keep records") }
    public static var uninstallDeleteRecords: String { L10n.text(zh: "卸载并删除它的全部记录", en: "Uninstall and delete all its records") }
    public static var pluginDeleteNote: String { L10n.text(zh: "插件会先停用。删除记录不能恢复，相关事项与总结会按剩余记录重新整理。", en: "The plugin is disabled first. Deleting its records is permanent, and affected summaries are rebuilt from the remaining records.") }
    public static var pluginInstalled: String { L10n.text(zh: "已安装，确认配置后可开启。", en: "Installed. Confirm the configuration before enabling it.") }
    public static var pluginSaved: String { L10n.text(zh: "已保存，下次运行时生效。", en: "Saved. Changes apply on the next run.") }
    public static var pluginDeleted: String { L10n.text(zh: "已卸载并删除相关记录。", en: "Uninstalled and deleted its records.") }
    public static var pluginUninstalled: String { L10n.text(zh: "已卸载，历史记录已保留。", en: "Uninstalled and kept its records.") }

    // MARK: - Relay mailbox

    public static var relayMailbox: String { L10n.text(zh: "中转信箱", en: "Relay mailbox") }
    public static var yourMailbox: String { L10n.text(zh: "自己的信箱", en: "Your own mailbox") }
    public static var currentAddress: String { L10n.text(zh: "当前地址", en: "Current address") }
    public static var lastMailboxFetch: String { L10n.text(zh: "上次取信", en: "Last retrieval") }
    public static var mailboxRequestsToday: String { L10n.text(zh: "今天的信箱请求", en: "Mailbox requests today") }
    public static var awaitingRetrieval: String { L10n.text(zh: "待取", en: "Awaiting retrieval") }
    public static var loadingRelaySettings: String { L10n.text(zh: "正在读取信箱设置…", en: "Loading relay mailbox settings…") }
    public static var relayTestPassed: String { L10n.text(zh: "连接测试通过。", en: "Connection test passed.") }
    public static var relayNote: String { L10n.text(zh: "信箱只经手加密内容，能看到传输的时间和大小。", en: "The relay mailbox handles encrypted content and can see transfer times and sizes.") }
    public static var disableRelayQuestion: String { L10n.text(zh: "关闭中转信箱？", en: "Turn off the relay mailbox?") }
    public static var disableRelay: String { L10n.text(zh: "关闭信箱", en: "Turn off mailbox") }
    public static var disableRelayNote: String { L10n.text(zh: "关闭后，不在同一个局域网的设备无法同步，旧信箱里的内容 7 天后清掉。", en: "Devices will only sync on the same local network, and the old mailbox clears its contents after 7 days.") }
    public static var relayAddress: String { L10n.text(zh: "信箱地址", en: "Mailbox address") }
    public static var activationCode: String { L10n.text(zh: "开通码", en: "Activation code") }
    public static var optionalField: String { L10n.text(zh: "可留空", en: "Optional") }
    public static var relaySettingsUnavailable: String { L10n.text(zh: "暂时无法读取信箱设置。", en: "Can't read relay mailbox settings right now.") }
    /// 读取失败时在原句后面补一句原因，例如“暂时无法读取设备：连不上后台服务。”
    public static func unavailable(_ sentence: String, because reason: String) -> String {
      let base = sentence.trimmingCharacters(in: CharacterSet(charactersIn: "。."))
      return L10n.text(zh: "\(base)：\(reason)。", en: "\(base): \(reason).")
    }
    public static var reasonUnreachable: String { L10n.text(zh: "连不上后台服务", en: "can't reach the background service") }
    public static var reasonTimedOut: String { L10n.text(zh: "后台服务没有响应，可能正忙", en: "the background service didn't respond and may be busy") }
    public static var reasonDeviceLink: String { L10n.text(zh: "这台 Mac 和后台之间的加密连接还没建好", en: "this Mac's secure link to the background service isn't ready") }
    public static var reasonBadResponse: String { L10n.text(zh: "后台返回的内容读不出来，可能版本不一致", en: "the background service sent a reply this version can't read") }
    public static var reasonServer: String { L10n.text(zh: "后台服务出错了", en: "the background service ran into an error") }

    // MARK: - Devices and invitations

    public static var devices: String { L10n.text(zh: "设备", en: "Devices") }
    public static var updateBackendForDevices: String { L10n.text(zh: "需要更新后台服务才能管理设备。", en: "Update the background service to manage devices.") }
    public static var addDevice: String { L10n.text(zh: "添加设备", en: "Add device") }
    public static var loadingDevices: String { L10n.text(zh: "正在读取设备…", en: "Loading devices…") }
    public static var demoteDeviceNote: String { L10n.text(zh: "改完不能在这里改回管理，要用新的管理邀请重新配对。", en: "Restoring management access requires pairing again with a new management invite.") }
    public static var remove: String { L10n.text(zh: "移除", en: "Remove") }
    public static var removeDeviceFailed: String { L10n.text(zh: "无法移除设备，请重试。", en: "Couldn't remove the device. Try again.") }
    public static var removeDeviceNote: String { L10n.text(zh: "已保存的记录会保留，这台设备要重新配对才能再连接。", en: "Saved records are kept. This device will need to pair again to connect.") }
    public static var macInviteNote: String { L10n.text(zh: "复制邀请链接，在另一台 Mac 的“设置 → 后台与连接 → 连接远端后台”里粘贴。", en: "Copy the invite link, then paste it under Settings → Background service and connection → Connect to a remote service on the other Mac.") }
    public static var scanQRCode: String { L10n.text(zh: "用手机扫描二维码", en: "Scan the QR code with your phone") }
    public static var qrCodeUnavailable: String { L10n.text(zh: "二维码无法显示，请复制邀请链接。", en: "The QR code couldn't be displayed. Copy the invite link to continue.") }
    public static var inviteLink: String { L10n.text(zh: "邀请链接", en: "Invite link") }
    public static var copyInviteLink: String { L10n.text(zh: "复制邀请链接", en: "Copy invite link") }
    public static var inviteExpired: String { L10n.text(zh: "邀请已过期", en: "Invite expired") }
    public static var generateAgain: String { L10n.text(zh: "重新生成", en: "Generate again") }
    public static var devicesUnavailable: String { L10n.text(zh: "暂时无法读取设备。", en: "Can't read devices right now.") }
    public static var invalidInviteExpiry: String { L10n.text(zh: "邀请有效期格式错误", en: "The invitation has an invalid expiration time") }
    public static var createInviteFailed: String { L10n.text(zh: "无法生成邀请，请重试。", en: "Couldn't create the invite. Try again.") }
    public static var cancelInviteFailed: String { L10n.text(zh: "无法取消邀请，请重试。", en: "Couldn't cancel the invite. Try again.") }
    public static var changeDeviceRoleFailed: String { L10n.text(zh: "无法修改设备权限，请重试。", en: "Couldn't change device permissions. Try again.") }
    public static var noRecentConnection: String { L10n.text(zh: "暂无连接", en: "No connection yet") }
    public static var lastConnection: String { L10n.text(zh: "最近连接", en: "Last connection") }
    public static var grantMacAdminNote: String { L10n.text(zh: "另一台 Mac 会得到管理权限，能删除记录和修改设置；邀请 5 分钟内有效，配好后可以改为查看。", en: "The other Mac can delete records and change settings with management access. This invite expires in 5 minutes, and you can switch the Mac to view access after pairing.") }
    public static var back: String { L10n.text(zh: "返回", en: "Back") }
    public static var phone: String { L10n.text(zh: "手机", en: "Phone") }
    public static var anotherMac: String { L10n.text(zh: "另一台 Mac", en: "Another Mac") }
    public static var generateInvite: String { L10n.text(zh: "生成邀请", en: "Generate invite") }
    public static var grantAdminQuestion: String { L10n.text(zh: "授予管理权限？", en: "Grant management access?") }
    public static var collectRole: String { L10n.text(zh: "采集", en: "Collect") }
    public static var viewRole: String { L10n.text(zh: "查看", en: "View") }
    public static var adminRole: String { L10n.text(zh: "管理", en: "Manage") }

    // MARK: - Remote background service

    public static var connectRemote: String { L10n.text(zh: "连接远端后台", en: "Connect to a remote service") }
    public static var returnInterrupted: String { L10n.text(zh: "上次切回尚未完成。", en: "The last switch back didn't finish.") }
    public static var cancelReturn: String { L10n.text(zh: "取消切回", en: "Cancel switch back") }
    public static var cancelRePairing: String { L10n.text(zh: "取消重新配对", en: "Cancel pairing again") }
    public static var resumeSwitch: String { L10n.text(zh: "恢复切换", en: "Resume switch") }
    public static var remoteBackend: String { L10n.text(zh: "远端后台", en: "Remote background service") }
    public static var checkingConnection: String { L10n.text(zh: "正在检查连接…", en: "Checking connection…") }
    public static var gotIt: String { L10n.text(zh: "知道了", en: "Got it") }
    public static var localBackup: String { L10n.text(zh: "本机备份", en: "Local backup") }
    public static var remoteCannotVerifyMac: String { L10n.text(zh: "远端后台无法验证这台 Mac，新的记录会在本机等待保存。", en: "The remote background service couldn't verify this Mac. New records will wait here until they can be saved.") }
    public static var directAddress: String { L10n.text(zh: "直连地址", en: "Direct address") }
    public static var restoreConnection: String { L10n.text(zh: "用原连接恢复", en: "Restore original connection") }
    public static var rePair: String { L10n.text(zh: "重新配对", en: "Pair again") }
    public static var verifyingOriginalConnection: String { L10n.text(zh: "正在验证原连接…", en: "Verifying the original connection…") }
    public static var pasteInvite: String { L10n.text(zh: "粘贴邀请链接", en: "Paste invite link") }
    public static var serviceName: String { L10n.text(zh: "服务名称", en: "Service name") }
    public static var expires: String { L10n.text(zh: "有效期", en: "Expires") }
    public static var checkConnection: String { L10n.text(zh: "检查连接", en: "Check connection") }
    public static var connectionType: String { L10n.text(zh: "连接方式", en: "Connection type") }
    public static var continueAction: String { L10n.text(zh: "继续", en: "Continue") }
    public static var confirmedRemoteUnavailable: String { L10n.text(zh: "无法读取已确认的远端后台。", en: "Can't read the confirmed remote background service.") }
    public static var readyToUpload: String { L10n.text(zh: "准备上传", en: "Ready to upload") }
    public static var privateRecordsStayLocal: String { L10n.text(zh: "私密记录留在本机", en: "Private records kept on this Mac") }
    public static var backupLocation: String { L10n.text(zh: "备份位置", en: "Backup location") }
    public static var confirmRePairDevices: String { L10n.text(zh: "我确认这些设备需要在远端后台重新配对", en: "I understand these devices need to pair with the remote background service again") }
    public static var switchBackend: String { L10n.text(zh: "切换后台", en: "Switch background service") }
    public static var countingHistory: String { L10n.text(zh: "正在统计历史记录…", en: "Counting earlier records…") }
    public static var alreadyPresent: String { L10n.text(zh: "已存在", en: "Already present") }
    public static var skipped: String { L10n.text(zh: "已跳过", en: "Skipped") }
    public static var needsAttention: String { L10n.text(zh: "需要处理", en: "Needs attention") }
    public static var newRecordsWaitingToSave: String { L10n.text(zh: "新记录等待保存", en: "New records waiting to save") }
    public static var resumeSync: String { L10n.text(zh: "继续同步", en: "Resume sync") }
    public static var pauseSync: String { L10n.text(zh: "暂停同步", en: "Pause sync") }
    public static var switchBack: String { L10n.text(zh: "切回这台 Mac", en: "Switch back to this Mac") }
    public static var setUpModels: String { L10n.text(zh: "设置模型", en: "Set up models") }
    public static var backupDate: String { L10n.text(zh: "备份日期", en: "Backup date") }
    public static var storageUsed: String { L10n.text(zh: "占用空间", en: "Storage used") }
    public static var privateRecords: String { L10n.text(zh: "私密记录", en: "Private records") }
    public static var notUploaded: String { L10n.text(zh: "未上传记录", en: "Records not uploaded") }
    public static var lastReconciled: String { L10n.text(zh: "上次核对", en: "Last checked") }
    public static var notReconciled: String { L10n.text(zh: "尚未核对", en: "Not checked yet") }
    public static var deleteLocalBackupEllipsis: String { L10n.text(zh: "删除本机备份…", en: "Delete local backup…") }
    public static var temporarilyUnavailable: String { L10n.text(zh: "暂时无法读取", en: "Temporarily unavailable") }
    public static var recordsSaved: String { L10n.text(zh: "已保存记录", en: "Saved records") }
    public static var historySync: String { L10n.text(zh: "历史同步", en: "History sync") }
    public static var confirmed: String { L10n.text(zh: "已确认", en: "Confirmed") }
    public static var retryScheduled: String { L10n.text(zh: "已安排重试。", en: "Retry scheduled.") }
    public static var retryingRecords: String { L10n.text(zh: "正在重试记录…", en: "Retrying records…") }
    public static var keptInLocalBackup: String { L10n.text(zh: "这些记录仍在本机备份中。", en: "These records are still in the local backup.") }
    public static var keepInBackup: String { L10n.text(zh: "留在备份", en: "Keep in backup") }
    public static var recordID: String { L10n.text(zh: "记录编号：", en: "Record ID:") }
    public static var remoteRecordConflict: String { L10n.text(zh: "远端已有不同版本", en: "A different version already exists on the remote service") }
    public static var remoteDeviceCollision: String { L10n.text(zh: "记录所属设备冲突", en: "The record belongs to a different device") }
    public static var correctionTargetMissing: String { L10n.text(zh: "找不到修正对应的原记录", en: "The original record for this correction couldn't be found") }
    public static var recordOnlyLocal: String { L10n.text(zh: "这条记录仅保留在本机", en: "This record is kept on this Mac") }
    public static var recordKeptInBackup: String { L10n.text(zh: "已留在本机备份", en: "Kept in the local backup") }
    public static var remoteReceiptInvalid: String { L10n.text(zh: "无法核对远端确认结果", en: "Couldn't verify the remote receipt") }
    public static var localBackupUnavailable: String { L10n.text(zh: "无法读取本机备份", en: "Can't read the local backup") }
    public static var syncAuthorizationExpired: String { L10n.text(zh: "历史同步授权已到期", en: "History sync authorization expired") }
    public static var remoteOrBackupUnavailable: String { L10n.text(zh: "暂时无法连接远端后台或读取备份", en: "The remote service or local backup is temporarily unavailable") }
    public static var syncRecordTooLarge: String { L10n.text(zh: "记录超出当前连接的容量", en: "The record is too large for this connection") }
    public static var remoteRecordRejected: String { L10n.text(zh: "远端后台未接受这条记录", en: "The remote background service declined this record") }
    public static var backupRecoveryNote: String { L10n.text(zh: "删除后只能建立空的本机后台，仍可连接远端查看已保存的记录。", en: "After deletion, this Mac can start with an empty local background service. Saved records remain available from the remote service.") }
    public static var switchBackQuestion: String { L10n.text(zh: "切回这台 Mac？", en: "Switch back to this Mac?") }
    public static var remoteDataStays: String { L10n.text(zh: "已保存到远端的记录和整理结果会留在远端。", en: "Records and summaries saved to the remote service will stay there.") }
    public static var recordsToBringBack: String { L10n.text(zh: "可转回本机的待发记录", en: "Pending records that can move back to this Mac") }
    public static var switchingBack: String { L10n.text(zh: "正在切回…", en: "Switching back…") }
    public static var reconciling: String { L10n.text(zh: "正在核对…", en: "Checking records…") }
    public static var deleteLocalBackupQuestion: String { L10n.text(zh: "删除本机备份？", en: "Delete local backup?") }
    public static var deleteBackupNote: String { L10n.text(zh: "备份里仅存在于这台 Mac 的记录会永久删除。", en: "Records stored only in this backup will be permanently deleted.") }
    public static var deleteLocalBackup: String { L10n.text(zh: "删除本机备份", en: "Delete local backup") }
    public static var deleting: String { L10n.text(zh: "正在删除…", en: "Deleting…") }
    public static var notCounted: String { L10n.text(zh: "尚未统计", en: "Not counted yet") }
    public static var chooseConnection: String { L10n.text(zh: "选择连接", en: "Choose connection") }
    public static var confirmTarget: String { L10n.text(zh: "确认目标", en: "Confirm destination") }
    public static var confirmSwitch: String { L10n.text(zh: "确认切换", en: "Confirm switch") }
    public static var syncHistory: String { L10n.text(zh: "同步历史", en: "Sync history") }
    public static var useRemote: String { L10n.text(zh: "使用远端", en: "Use remote service") }
    public static var emptyLocalBackendNote: String { L10n.text(zh: "本机备份已删除，切回只能建立空的本机后台。", en: "The local backup was deleted, so switching back starts an empty local background service.") }
    public static var reconcileBeforeReturn: String { L10n.text(zh: "切回前会核对本机备份与远端的删除和私密变更。", en: "Switching back first checks the local backup against remote deletions and privacy changes.") }
    public static var validInviteRequired: String { L10n.text(zh: "请粘贴有效的邀请链接。", en: "Paste a valid invite link.") }
    public static var rePairInterrupted: String { L10n.text(zh: "上次重新配对尚未完成。", en: "The last attempt to pair again didn't finish.") }
    public static var switchInterrupted: String { L10n.text(zh: "上次后台切换尚未完成。", en: "The last background service switch didn't finish.") }
    public static var unfinishedPairingNote: String { L10n.text(zh: "远端后台可能留有一条未完成的配对，请在远端后台的设备列表里移除。", en: "Check the remote background service's device list and remove any unfinished pairing for this Mac.") }
    public static var expiredReplacementInvite: String { L10n.text(zh: "邀请链接已过期，请返回并粘贴新链接。", en: "The invite link has expired. Go back and paste a new link.") }
    public static var awaitingRemoteConfirmation: String { L10n.text(zh: "正在等待远端后台确认…", en: "Waiting for the remote background service to confirm…") }
    public static var managementDirectNotice: String { L10n.text(zh: "管理远端后台和使用 AI 工具需要直连。", en: "Connect directly to manage the remote background service and use AI tools.") }
    public static var modelsDirectNotice: String { L10n.text(zh: "修改远端后台的模型设置需要直连。", en: "Connect directly to change model settings on the remote background service.") }
    public static var agentDirectAddressMissing: String { L10n.text(zh: "AI 工具尚未获得直连地址。", en: "AI tools are waiting for a direct address.") }
    public static var connectionInterrupted: String { L10n.text(zh: "连接已中断", en: "Connection interrupted") }
    public static var remoteUnresponsive: String { L10n.text(zh: "远端后台没有回应", en: "The remote background service didn't respond") }
    public static var connectionUnavailable: String { L10n.text(zh: "连接不可用", en: "Connection unavailable") }
    public static var historySyncPaused: String { L10n.text(zh: "历史同步已暂停。", en: "History sync paused.") }
    public static var resumeHistoryWhenConnected: String { L10n.text(zh: "恢复连接后继续同步历史。", en: "History sync resumes when the connection returns.") }
    public static var resumeWhenConnected: String { L10n.text(zh: "等连接恢复后继续。", en: "Resumes when the connection returns.") }
    public static var historySyncProblem: String { L10n.text(zh: "历史同步遇到问题，可在详细状态中查看。", en: "History sync ran into a problem. See Detailed status for more.") }
    public static var deleteBlockedDuringReturn: String { L10n.text(zh: "切回期间不能删除备份。", en: "Wait until the switch back finishes to delete the backup.") }
    public static var deleteBlockedPendingReceipt: String { L10n.text(zh: "还有记录未确认，暂时不能删除备份。", en: "Wait for all records to be confirmed before deleting the backup.") }
    public static var deleteBlockedDuringSync: String { L10n.text(zh: "历史同步完成后才能删除备份。", en: "Wait for history sync to finish before deleting the backup.") }
    public static var backupInUse: String { L10n.text(zh: "备份仍在使用，暂时不能删除。", en: "The backup is still in use.") }
    public static var backendConnectionStatusUnavailable: String { L10n.text(zh: "无法读取后台连接状态。", en: "Couldn't read the background service connection status.") }
    public static var recoverRePairFailed: String { L10n.text(zh: "无法恢复上次的重新配对。", en: "Couldn't resume the last pairing attempt.") }
    public static var remoteCheckFailed: String { L10n.text(zh: "无法检查远端后台，请重试。", en: "Couldn't check the remote background service. Try again.") }
    public static var readLocalSwitchDataFailed: String { L10n.text(zh: "无法读取本机记录或已配对设备，请重试。", en: "Couldn't read local records or paired devices. Try again.") }
    public static var switchBackendFailed: String { L10n.text(zh: "无法切换后台，请重试。", en: "Couldn't switch background services. Try again.") }
    public static var rePairFailed: String { L10n.text(zh: "无法完成重新配对，请重试。", en: "Couldn't pair again. Try again.") }
    public static var cancelPairingFailed: String { L10n.text(zh: "无法取消这次配对，请重试。", en: "Couldn't cancel pairing. Try again.") }
    public static var reauthenticateFailed: String { L10n.text(zh: "无法用原连接恢复，请直连后台后重试或重新配对。", en: "Couldn't restore the original connection. Connect directly and retry, or pair again.") }
    public static var changeSyncFailed: String { L10n.text(zh: "无法更改历史同步状态，请重试。", en: "Couldn't change history sync. Try again.") }
    public static var deleteBackupFailed: String { L10n.text(zh: "当前无法删除本机备份。", en: "Can't delete the local backup right now.") }
    public static var returnCountUnavailable: String { L10n.text(zh: "无法读取可转回本机的记录数量，请重试。", en: "Couldn't count the records that can move back to this Mac. Try again.") }
    public static var switchBackFailed: String { L10n.text(zh: "无法切回这台 Mac，当前仍使用远端后台。", en: "Couldn't switch back to this Mac. The remote background service is still in use.") }
    public static var cancelReturnFailed: String { L10n.text(zh: "无法取消切回，请重试。", en: "Couldn't cancel the switch back. Try again.") }
    public static var recoverSwitchFailed: String { L10n.text(zh: "无法恢复上次的后台切换，请重试。", en: "Couldn't resume the last background service switch. Try again.") }
    public static var cancelRePairFailed: String { L10n.text(zh: "无法取消这次重新配对，请重试。", en: "Couldn't cancel this pairing attempt. Try again.") }
    public static var reconnectFailed: String { L10n.text(zh: "无法重新连接这个远端后台，请重试。", en: "Couldn't reconnect to this remote background service. Try again.") }
    public static var schedulingRetry: String { L10n.text(zh: "正在安排重试…", en: "Scheduling retry…") }
    public static var retryRecordFailed: String { L10n.text(zh: "无法重试这条记录，请稍后再试。", en: "Couldn't retry this record. Try again shortly.") }
    public static var updatingRecordStatus: String { L10n.text(zh: "正在更新记录状态…", en: "Updating record status…") }
    public static var updateRecordStatusFailed: String { L10n.text(zh: "无法更改这条记录的状态，请稍后再试。", en: "Couldn't change this record's status. Try again shortly.") }
    public static var dismissNoticeFailed: String { L10n.text(zh: "无法关闭这条提示，请重试。", en: "Couldn't dismiss this notice. Try again.") }
    public static var invalidInviteLink: String { L10n.text(zh: "邀请链接无法使用，请检查是否复制完整。", en: "The invite link is invalid. Check that you copied the full link.") }
    public static var inviteUnavailable: String { L10n.text(zh: "邀请链接已过期或已使用，请粘贴新链接。", en: "The invite link expired or was already used. Paste a new one.") }
    public static var inviteWrongBackend: String { L10n.text(zh: "请粘贴当前后台签发的邀请链接，连接其他后台前需先切回这台 Mac。", en: "Paste an invite from the current background service. Switch back to this Mac before connecting to another service.") }
    public static var returnWaitingForReconciliation: String { L10n.text(zh: "远端的删除和私密变更尚未核对完成，当前仍使用远端后台。", en: "The remote background service remains in use while deletions and privacy changes are checked.") }
    public static var backendTimedOut: String { L10n.text(zh: "后台服务等待超时，请查看详细状态。", en: "The background service timed out. See Detailed status for more.") }
    public static var setUpModelToStart: String { L10n.text(zh: "设置模型后开始整理。", en: "Set up a model to start summarizing.") }

    // MARK: - Installation and local services

    public static var temporaryAppLocation: String { L10n.text(zh: "macOS 正把 Tacit 放在临时位置运行", en: "macOS is running Tacit from a temporary location") }
    public static var moveAppAndBack: String { L10n.text(zh: "在访达里把 Tacit 从“应用程序”拖到桌面，再拖回“应用程序”，然后重新打开。", en: "In Finder, move Tacit from Applications to the desktop and back, then open it again.") }
    public static var moveAppToApplications: String { L10n.text(zh: "请先把 Tacit 拖到“应用程序”文件夹", en: "Move Tacit to the Applications folder") }
    public static var launchFromApplications: String { L10n.text(zh: "从“应用程序”文件夹打开后，Tacit 才能在后台持续记录，并在登录时自动启动。", en: "Open Tacit from Applications to record in the background and start automatically at login.") }
    public static var openApplications: String { L10n.text(zh: "打开“应用程序”文件夹", en: "Open Applications folder") }
    public static var quit: String { L10n.text(zh: "退出", en: "Quit") }
    public static var backendSwitchBusy: String { L10n.text(zh: "后台切换已经在进行。", en: "A background service switch is already in progress.") }
    public static var invalidSwitchCheckpoint: String { L10n.text(zh: "无法核对上一次后台切换的状态。", en: "Couldn't verify the last background service switch.") }
    public static var pendingOperationsTimedOut: String { L10n.text(zh: "后台仍有操作未确认，等待超时。", en: "Timed out waiting for the background service to confirm pending operations.") }
    public static var outboxNotPersisted: String { L10n.text(zh: "待发送记录尚未安全保存。", en: "Pending records haven't been saved securely yet.") }
    public static var reconciliationIncomplete: String { L10n.text(zh: "远端删除和私密变更尚未核对完成。", en: "Remote deletions and privacy changes are still being checked.") }
    public static var localServicesUnavailable: String { L10n.text(zh: "无法停止或恢复这台 Mac 的后台服务。", en: "Couldn't stop or restore this Mac's background service.") }
    public static var localDatabaseInUse: String { L10n.text(zh: "本机数据库仍在使用或未安全关闭。", en: "The local database is still in use or didn't close safely.") }
    public static var localBackendUnverified: String { L10n.text(zh: "无法验证本机后台的身份或写入状态。", en: "Couldn't verify the local background service or its ability to save records.") }
    public static var backendSwitchNeedsRecovery: String { L10n.text(zh: "后台切换仍需恢复，已保留进度。", en: "Progress was saved. Resume the background service switch to finish.") }
    public static var localRecordCountUnavailable: String { L10n.text(zh: "无法读取本机记录数量。", en: "Couldn't count the local records.") }
    public static var localBackendRequired: String { L10n.text(zh: "需要连接这台 Mac 的后台", en: "Connect to this Mac's background service") }
    public static var installFolderMissing: String { L10n.text(zh: "找不到安装目录，请重新安装应用。", en: "Reinstall Tacit to restore the installation folder.") }
    public static var switchingBackend: String { L10n.text(zh: "正在切换后台", en: "Switching background services") }
    public static var repoMissing: String { L10n.text(zh: "未配置仓库", en: "Installation folder not configured") }
    public static var backendDeviceUnavailable: String { L10n.text(zh: "后台设备连接不可用", en: "Device connection to the background service is unavailable") }
    public static var disabledOrPaused: String { L10n.text(zh: "已停用或暂停", en: "Disabled or paused") }
    public static var failedToStart: String { L10n.text(zh: "启动失败", en: "Couldn't start") }


    // MARK: - Formatted labels

    public static var language: String { L10n.text(zh: "语言", en: "Language") }
    public static var displayLanguage: String { L10n.text(zh: "显示语言", en: "Display language") }
    public static var languageNote: String {
      L10n.text(zh: "切换语言只影响之后的整理结果。", en: "Changing language applies only to future summaries.")
    }

    public static func languageOption(_ preference: LanguagePreference, lang: AppLanguage = .current) -> String {
      switch preference {
      case .system: return L10n.text(zh: "跟随系统", en: "Follow system", lang: lang)
      case .zh: return "中文"
      case .en: return "English"
      }
    }

    public static func appVersion(_ version: String) -> String {
      L10n.text(zh: "版本 \(version)", en: "Version \(version)")
    }
    public static var checkForUpdates: String { L10n.text(zh: "检查更新", en: "Check for updates") }
    public static var upToDate: String { L10n.text(zh: "已是最新", en: "Up to date") }
    public static var updateCheckFailed: String { L10n.text(zh: "暂时连不上", en: "Couldn’t connect") }
    public static func updateTo(_ version: String) -> String {
      L10n.text(zh: "更新到 \(version)", en: "Update to \(version)")
    }

    public static func recordCount(_ count: Int, chineseUsesSystemLocale: Bool = false, lang: AppLanguage = .current) -> String {
      L10n.count(count, one: "%@ record", other: "%@ records",
                 zh: "\(chineseUsesSystemLocale ? count.formatted() : L10n.number(count)) 条", lang: lang)
    }

    public static func pausedUntil(_ time: String) -> String {
      L10n.text(zh: "已暂停到 \(time)", en: "Paused until \(time)")
    }

    public static func keyBackup(onThisMac: Bool) -> String {
      L10n.text(zh: onThisMac ? "这台 Mac 的密钥备份" : "密钥备份",
                en: onThisMac ? "Key backup on this Mac" : "Key backup")
    }

    public static func dataFolder(onThisMac: Bool) -> String {
      L10n.text(zh: onThisMac ? "这台 Mac 的记录与音频的数据目录" : "记录与音频的数据目录",
                en: onThisMac ? "Folder for records and audio on this Mac" : "Folder for records and audio")
    }

    public static func summaryStatus(_ status: String) -> String {
      L10n.text(zh: "整理：\(status)", en: "Summary: \(status)")
    }

    public static func integerInRange(_ lower: Int, _ upper: Int) -> String {
      L10n.text(zh: "请输入 \(lower)–\(upper) 之间的整数。",
                en: "Enter a whole number from \(L10n.number(lower)) to \(L10n.number(upper)).")
    }

    public static var listSeparator: String { L10n.text(zh: "，", en: ", ") }

    public static func lastRunAt(_ time: String) -> String {
      L10n.text(zh: "上次运行 \(time)", en: "Last run at \(time)")
    }

    public static func enableSource(_ name: String) -> String {
      L10n.text(zh: "启用\(name)", en: "Enable \(name)")
    }

    public static func permissionLabel(_ name: String) -> String {
      L10n.text(zh: "\(name)权限", en: "\(L10n.permission(name)) permission")
    }

    public static func missingPermissions(_ names: [String]) -> String {
      L10n.text(zh: "还缺" + names.joined(separator: "、") + "权限。",
                en: "Grant " + names.map(L10n.permission).formatted(.list(type: .and).locale(AppLanguage.en.locale())) + " access.")
    }

    /// The wire format reserves 0 for keeping audio indefinitely.
    public static func audioRetentionValue(keepForever: Bool, days: Int) -> Int? {
      if keepForever { return 0 }
      return (1...365).contains(days) ? days : nil
    }

    public static func retentionUnit(_ days: Int, lang: AppLanguage = .current) -> String {
      L10n.text(zh: "天", en: days == 1 ? "day" : "days", lang: lang)
    }

    public static func removeAdminQuestion(_ name: String) -> String {
      L10n.text(zh: "取消“\(name)”的管理权限？", en: "Remove management access for “\(name)”?")
    }

    public static func changeRole(_ role: String) -> String {
      L10n.text(zh: "改为\(role)", en: "Change to \(role.lowercased()) access")
    }

    public static func removeDeviceQuestion(_ name: String) -> String {
      L10n.text(zh: "移除“\(name)”？", en: "Remove “\(name)”?")
    }

    public static func deviceConnected(_ name: String) -> String {
      L10n.text(zh: "已连接 \(name)", en: "Connected to \(name)")
    }

    public static func deviceActions(_ name: String) -> String {
      L10n.text(zh: "\(name)的操作", en: "Actions for \(name)")
    }

    public static func inviteCountdown(minutes: Int, seconds: Int, lang: AppLanguage = .current) -> String {
      if lang == .en {
        let parts = [minutes > 0 ? "\(L10n.number(minutes)) min" : nil,
                     seconds > 0 || minutes == 0 ? "\(L10n.number(seconds)) sec" : nil].compactMap { $0 }
        return parts.joined(separator: " ") + " remaining"
      }
      if minutes == 0 { return "剩余 \(seconds) 秒" }
      if seconds == 0 { return "剩余 \(minutes) 分钟" }
      return "剩余 \(minutes) 分 \(seconds) 秒"
    }

    public static func revision(_ value: String, previous: Bool) -> String {
      L10n.text(zh: (previous ? "原提交：" : "固定提交：") + value,
                en: (previous ? "Previous commit: " : "Pinned commit: ") + value)
    }

    public static func readPath(_ label: String, path: String, includesSubfolders: Bool) -> String {
      let suffix = L10n.text(zh: includesSubfolders ? "（含子目录）：" : "：",
                             en: includesSubfolders ? " (including subfolders): " : ": ")
      return label + suffix + (path.isEmpty ? unspecified : path)
    }

    public static func uninstallQuestion(_ name: String) -> String {
      L10n.text(zh: "卸载“\(name)”？", en: "Uninstall “\(name)”?")
    }

    public static func usageLine(_ usage: ModelUsageSummary) -> String? {
      guard AppLanguage.current == .en else { return usage.line }
      guard usage.daysWithUsage > 0, let daily = usage.averageDailyTokens,
            let timeline = usage.averageDailyTimelineTokens else { return nil }
      let countFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).locale(AppLanguage.en.locale(region: "US"))
      let dailyTokens = daily.formatted(countFormat)
      let timelineTokens = timeline.formatted(countFormat)
      let today = L10n.number(usage.todayTokens)
      return "7-day average: \(dailyTokens) tokens per day, including \(timelineTokens) for the timeline. Today: \(today) tokens."
    }

    public static func providerName(_ provider: String, fallback: String) -> String {
      guard AppLanguage.current == .en else { return fallback }
      switch provider {
      case "claude-cli": return "Claude Code account"
      case "codex-cli": return "Codex account"
      case "openai-compatible": return "OpenAI-compatible API or proxy"
      default: return fallback
      }
    }

    public static func tierName(_ tier: String, fallback: String) -> String {
      guard AppLanguage.current == .en else { return fallback }
      switch tier {
      case "minute": return "Live"
      case "hour": return "Hourly roundup"
      case "day": return "Daily timeline"
      default: return fallback
      }
    }

    public static func tierDescription(_ tier: String, fallback: String?) -> String? {
      guard AppLanguage.current == .en else { return fallback }
      switch tier {
      case "minute": return "Groups new records into tasks and projects every 15 minutes. A faster model works well here."
      case "hour": return "Updates task details and summarizes progress for each project every hour."
      case "day": return "Writes daily timelines and day overviews, and summarizes earlier history."
      default: return fallback
      }
    }

    public static func connectionDuration(_ seconds: Double) -> String {
      let duration = String(format: "%.1f", seconds)
      return L10n.text(zh: "连接正常，用时 \(duration) 秒。", en: "Connected in \(duration) sec.")
    }

    public static func setAPIKey(_ provider: String) -> String {
      L10n.text(zh: "设置 \(provider) 的 API key", en: "Set API key for \(provider)")
    }

    public static var directConnection: String { L10n.text(zh: "直连", en: "Direct connection") }
    public static var viaRelay: String { L10n.text(zh: "通过中转信箱", en: "Via relay mailbox") }

    private static func gapBeforeName(_ name: String) -> String {
      name.first.map { $0.isASCII ? " " : "" } ?? ""
    }

    public static func reconnect(_ name: String) -> String {
      L10n.text(zh: "重新连接\(gapBeforeName(name))\(name)", en: "Reconnect to \(name)")
    }

    public static func connectedTo(_ name: String) -> String {
      L10n.text(zh: "已连接到\(gapBeforeName(name))\(name)", en: "Connected to \(name)")
    }

    public static func setupStep(_ step: Int) -> String {
      L10n.text(zh: "第 \(step) 步，共 3 步", en: "Step \(step) of 3")
    }

    public static func confirmedRecords(_ confirmed: Int, total: Int) -> String {
      L10n.count(total, one: "Confirmed \(L10n.number(confirmed)) of %@ record",
                 other: "Confirmed \(L10n.number(confirmed)) of %@ records",
                 zh: "已确认 \(confirmed.formatted()) / \(total.formatted()) 条")
    }

    public static func summarizedDays(_ done: Int, total: Int) -> String {
      L10n.count(total, one: "Summarized \(L10n.number(done)) of %@ day",
                 other: "Summarized \(L10n.number(done)) of %@ days",
                 zh: "已整理 \(done.formatted()) / \(total.formatted()) 天")
    }

    public static func remoteTimeZone(_ zone: String) -> String {
      L10n.text(zh: "远端后台的时区是\(gapBeforeName(zone))\(zone)，请管理员核对时间线使用的时区。",
                en: "The remote background service uses \(zone). Ask an administrator to check the timeline's time zone.")
    }

    public static func pairingError(_ failure: RemotePairing.Failure) -> String {
      guard AppLanguage.current == .en else { return failure.errorDescription ?? connectionFailed }
      switch failure {
      case .adminInvitationRequired: return "Use an invite link that grants management access."
      case .remoteUnavailable: return "Can't find the remote background service."
      case .preparationExists: return "Finish setting up or remove the existing remote connection first."
      case .invalidReceipt: return "The remote background service returned an invalid pairing confirmation."
      case .remoteCleanupRequired: return "Ask the server administrator to remove this pairing."
      case .differentHub: return inviteWrongBackend
      case .notFrozen: return "The remote connection is still in use. Restore it using the original connection."
      case .retainedIdentityInvalid: return "Paste a new invite link with management access from the remote background service."
      case .recoveryRequired: return "Pairing didn't finish. Progress was saved so you can resume."
      }
    }

    public static var preparingBackend: String { L10n.text(zh: "正在准备后台服务…", en: "Preparing the background service…") }
    public static var prepareAgain: String { L10n.text(zh: "重新准备", en: "Prepare again") }
    public static var goToModelSettings: String { L10n.text(zh: "去设置", en: "Open settings") }
    public static var noAvailableLocalModel: String {
      L10n.text(zh: "这台 Mac 上没有可用的 AI 模型。装好并登录 Claude Code 或 Codex，或在设置里填 API。",
                en: "No AI model is available on this Mac. Install and sign in to Claude Code or Codex, or configure an API in Settings.")
    }
    public static var offlinePortSaveFailed: String {
      L10n.text(zh: "端口没能保存，请检查数据文件夹的访问权限。",
                en: "The port couldn't be saved. Check access to the data folder.")
    }
    public static func setupFailure(_ reason: SetupStatus.Reason, lang: AppLanguage = .current) -> String {
      switch reason {
      case .bundleIncomplete:
        return L10n.text(zh: "Tacit 安装不完整。请从安装包重新安装。", en: "The Tacit installation is incomplete. Reinstall it from the installer.", lang: lang)
      case .database:
        return L10n.text(zh: "记录库打开失败。请确认钥匙串已解锁，已有记录库缺少密钥时请用密钥备份恢复。",
                         en: "The database could not be opened. Unlock the Keychain, or restore the key from backup if an existing database is missing its key.", lang: lang)
      case .backgroundBlocked:
        return L10n.text(zh: "系统没能启动后台服务。请在系统设置 › 通用 › 登录项与扩展里允许 Tacit 在后台运行，再点「重新准备」。",
                         en: "macOS couldn't start the background service. Allow Tacit in System Settings → General → Login Items & Extensions, then click Prepare again.", lang: lang)
      case .portInUse:
        return L10n.text(zh: "后台服务的端口被占用了。请在设置 › 后台与连接里更换端口。",
                         en: "The background service port is in use. Change it in Settings → Background service and connection.", lang: lang)
      case .serviceUnhealthy, .unknown:
        return L10n.text(zh: "后台服务没能启动。点「重新准备」再试。仍然失败时，可在设置 › 维护里复制诊断信息。",
                         en: "The background service couldn't start. Click Prepare again. If it still fails, copy diagnostics in Settings → Maintenance.", lang: lang)
      }
    }

    public static func speechModelDownloadMessage(stderr: String, lang: AppLanguage = .current) -> String {
      switch stderr.split(whereSeparator: \.isNewline).last {
      case "audio_models_error:network":
        return L10n.text(zh: "连不上下载地址，检查网络或代理后会自动重试", en: "Can't reach the download. Check your network or proxy. Tacit will retry automatically.", lang: lang)
      case "audio_models_error:checksum":
        return L10n.text(zh: "下载的文件不完整，会自动重新下载", en: "The downloaded file is incomplete. Tacit will download it again.", lang: lang)
      case "audio_models_error:disk":
        return L10n.text(zh: "磁盘空间不够，清理后会自动重试", en: "Free up disk space and Tacit will retry automatically.", lang: lang)
      case "audio_models_error:extract":
        return L10n.text(zh: "模型文件解压失败，会自动重试", en: "Couldn't unpack the model. Tacit will retry automatically.", lang: lang)
      default:
        return L10n.text(zh: "语音模型没能下载，稍后会自动重试", en: "Couldn't download the speech model. Tacit will retry shortly.", lang: lang)
      }
    }

    public static func speechModelInstallationMissing(lang: AppLanguage = .current) -> String {
      L10n.text(zh: "安装不完整，无法下载语音模型，请重新安装 Tacit",
                en: "Reinstall Tacit to download the speech model", lang: lang)
    }

    public static func speechModelDownloadFailed(_ reason: String, lang: AppLanguage = .current) -> String {
      L10n.text(zh: "语音模型下载失败" + (reason.isEmpty ? "" : "：\(reason)") + "。请检查网络，稍后会自动重试",
                en: "Couldn't download the speech model. Check your network. Tacit will retry automatically.", lang: lang)
    }

    public static func commandTimedOut(_ command: String) -> String {
      L10n.text(zh: "\(command) 等待超时。", en: "\(command) timed out.")
    }

    // Older background services and the local capture pipeline supply some status text in Chinese.
    private static func hasChineseText(_ text: String) -> Bool {
      text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    }

    public static func serviceMessage(_ message: String, fallback: String) -> String {
      guard UserFacingError.canDisplayServiceMessage(message) else { return fallback }
      guard AppLanguage.current == .en else { return message }
      switch message {
      case "不能移除最后一台管理设备": return "Keep at least one device with management access."
      case "手机只能使用采集权限": return "This phone supports collection access only."
      case "API key 格式不对：应为 8–1024 个英文字母、数字或符号，不能有空格、双引号或反斜杠。":
        return "Use 8–1,024 letters, numbers, or symbols for the API key. Omit spaces, double quotes, and backslashes."
      case "上一次测试还没结束": return "A test is already running."
      default: return fallback
      }
    }

    public static var settingsRequestFailed: String {
      L10n.text(zh: "后台服务暂时无法完成操作，请重试。", en: "The background service couldn't complete the request. Try again.")
    }

    public static var pluginOperationFailed: String {
      L10n.text(zh: "插件操作失败，请重试。", en: "Couldn't complete the plugin operation. Try again.")
    }

    public static var agentOperationFailed: String {
      L10n.text(zh: "无法更新 AI 工具的连接，请重试。", en: "Couldn't update the AI tool connection. Try again.")
    }

    public static func agentNote(_ note: String) -> String {
      if note == "第一次在 Codex 里开新会话时，它会请你批准一次，批准后才会自动带入。" {
        return L10n.text(zh: note, en: "The first new Codex session will ask you to approve access before session context is added.")
      }
      switch note {
      case "重开 Antigravity 后生效，它会在首次调用 Tacit 查询时请你批准。":
        return L10n.text(zh: note, en: "Reopen Antigravity, then approve its first Tacit query when prompted.")
      case "重开 Antigravity 后生效。":
        return reopenAgent("Antigravity")
      case "完全退出并重新打开 Claude Desktop 后生效。连接后可以问它“我昨天下午在做什么”。",
           "完全退出并重新打开 Claude Desktop 后生效。重启后将停止提供历史记录查询。":
        return L10n.text(zh: note, en: "Quit and reopen Claude Desktop to apply the change.")
      default:
        return serviceMessage(note, fallback: "")
      }
    }

    public static func modelFailure(_ problem: String, fallback: String) -> String {
      if ModelErrorText.isCode(problem) { return ModelErrorText.plain(problem) }
      return serviceMessage(problem, fallback: fallback)
    }

    public static var summaryFailure: String {
      L10n.text(zh: "整理没能完成，请检查模型设置。", en: "Summarizing failed. Check your model settings.")
    }

    public static func backgroundIssue(_ message: String) -> String {
      guard AppLanguage.current == .en, hasChineseText(message) else { return message }
      let messages: [(prefix: String, text: String)] = [
        ("待发送记录无法安全保存", "Pending records are being retried in memory. Check disk space and access to the data folder."),
        ("有待发送记录无法安全保存或恢复", "Some pending records couldn't be securely saved or restored."),
        ("已隔离", "Damaged pending records were quarantined."),
        ("后台连接配置无法读取", "The background service connection settings couldn't be read. Pending records are kept."),
        ("后台未确认完整接收", "The background service didn't confirm receipt of all records. Pending records are kept."),
        ("后台服务拒绝了记录", "The background service rejected the records."),
        ("找不到后台服务的访问凭证", "Restart Tacit to restore the background service credentials."),
        ("待发送记录超过上传大小限制", "Pending records exceed the upload size limit."),
        ("连不上后台服务", "Can't reach the background service."),
        ("待发送队列中有记录需要直连上传", "Some pending records need a direct connection to upload."),
        ("远端后台暂不可用", "The remote background service is temporarily unavailable. Pending records are kept."),
      ]
      if let match = messages.first(where: { message.hasPrefix($0.prefix) }) { return match.text }
      if message.contains("连接凭据不可用") { return "Background service credentials are unavailable. Pending records are kept." }
      if message.contains("发送结局未知") { return "Delivery couldn't be confirmed for some records from the pending queue." }
      return L10n.deliveryIssue(message)
    }

    public static func isDownloadingSpeechModel(_ status: String) -> Bool {
      status.hasPrefix("正在下载语音模型")
    }

    public static func recordingStatus(_ status: String) -> String {
      guard AppLanguage.current == .en, hasChineseText(status) else { return status }
      if status == speechModelInstallationMissing(lang: .zh) { return speechModelInstallationMissing() }
      if status.hasPrefix("语音模型下载失败") { return speechModelDownloadFailed("") }
      switch status {
      case "无法解除录音启动保护，请重启 Tacit 再试。": return "Restart Tacit and try enabling recording again."
      case "音频存储不可用，请检查磁盘空间后重启 Tacit。": return "Audio storage is unavailable. Check disk space and restart Tacit."
      case "录音启动失败，请检查麦克风权限和输入设备。", "麦克风启动失败，请检查麦克风权限和输入设备。":
        return "Recording couldn't start. Check microphone permission and the selected input."
      case "音频处理跟不上，已停止该路录音": return "Audio processing couldn't keep up, so this input stopped recording."
      case "麦克风处理失败，已停止录音。": return "Microphone processing failed and recording stopped."
      case "音频处理失败，已停止录音。": return "Audio processing failed and recording stopped."
      case "无法监听麦克风设备的变化。": return "Couldn't monitor changes to microphone devices."
      case "读不到麦克风设备列表。": return "Couldn't read the list of microphones."
      case "找不到自带麦克风", "麦克风找不到自带麦克风": return "Built-in microphone unavailable"
      case "音频存储操作失败。": return "Couldn't access audio storage."
      case "音频同步清理失败", "音频同步清理失败。": return "Couldn't clear audio during sync."
      case "音频目录检查失败": return "Couldn't check the audio folder."
      default: return L10n.audioStatus(status)
      }
    }

    public static func sourceStatus(_ status: String, source: String, succeeded: Bool) -> String {
      guard AppLanguage.current == .en, !status.isEmpty else { return status }
      if source == "audio" { return recordingStatus(status) }
      if source == "wechat", status.hasPrefix("“"), let end = status.range(of: "”新增 ", options: .backwards),
         let number = Int(status[end.upperBound...].dropLast(2)) {
        let chat = String(status[status.index(after: status.startIndex)..<end.lowerBound])
        return L10n.count(number, one: "%@ new message in “\(chat)”", other: "%@ new messages in “\(chat)”", zh: status)
      }
      return operationStatus(status, fallback: succeeded ? "Source ran successfully." : "The source couldn't run.")
    }

    public static func operationStatus(_ status: String, fallback: String = "See the Run log for details.") -> String {
      guard AppLanguage.current == .en, hasChineseText(status) else { return status }
      // Old capture snapshots can survive a language change until the source runs again.
      if status == "没有新记录" { return "No new records" }
      if status == "完成" { return "Done" }
      if status == "安装不完整，请重新安装 Tacit。" { return reinstallTacit }
      let fields = status.components(separatedBy: "，")
      if let first = fields.first, first.hasSuffix("完成"),
         let created = fields.dropFirst().first.flatMap(newRecordCount) {
        let result = L10n.count(created, one: "%@ new record", other: "%@ new records", zh: "")
        let failed = fields.contains { $0.hasSuffix("没有成功") }
        let summaryFailed = fields.contains { $0.hasPrefix("整理没能开始") }
        let problems = [failed ? "Some sources failed." : nil,
                        summaryFailed ? "Summarizing couldn't start." : nil].compactMap { $0 }
        let time = first.dropLast("完成".count)
        return "\(time)Done, \(result)." + (problems.isEmpty ? "" : " " + problems.joined(separator: " "))
      }
      if let first = fields.first, let created = newRecordCount(first) {
        return L10n.count(created, one: "%@ new record", other: "%@ new records", zh: "")
      }
      return fallback
    }

    private static func newRecordCount(_ text: String) -> Int? {
      guard text.hasPrefix("新增 "), text.hasSuffix(" 条") else { return nil }
      return Int(text.dropFirst(3).dropLast(2).replacingOccurrences(of: ",", with: ""))
    }

    public static var invalidRelayAddress: String {
      L10n.text(zh: RelaySettingsText.invalidAddress, en: "Enter a valid HTTPS mailbox address. Localhost can use HTTP.")
    }

    public static func relayConnection(_ settings: RelaySettings, now: Date = Date(), calendar: Calendar = .current) -> String? {
      guard AppLanguage.current == .en else { return RelaySettingsText.connection(settings, now: now, calendar: calendar) }
      guard settings.mode == .custom else { return nil }
      if let until = settings.pausedUntil.flatMap(ViewerTime.parse), until > now {
        let time = ViewerFormat.clock(until, calendar: calendar)
        let retryTime = calendar.isDate(until, inSameDayAs: now) ? "at \(time)" : "tomorrow at \(time)"
        return "The mailbox is limiting requests. Try again \(retryTime)."
      }
      return settings.connected ? nil : relayFailure(502)
    }

    public static func relayLastFetch(_ settings: RelaySettings) -> String? {
      guard AppLanguage.current == .en else { return RelaySettingsText.lastFetch(settings) }
      guard settings.mode == .custom, let date = settings.lastFetchAt.flatMap(ViewerTime.parse) else { return nil }
      return "\(relayDate(date)) \(ViewerFormat.clock(date))"
    }

    public static func relayPending(_ settings: RelaySettings) -> String? {
      guard AppLanguage.current == .en else { return RelaySettingsText.pending(settings) }
      guard settings.mode == .custom else { return nil }
      let total = settings.devices.compactMap(\.pending).filter { $0 > 0 }.reduce(0, +)
      return total > 0 ? L10n.count(total, one: "%@ item", other: "%@ items", zh: "") : nil
    }

    public static func relayUsage(_ settings: RelaySettings) -> (text: String, limited: Bool)? {
      guard AppLanguage.current == .en else { return RelaySettingsText.usage(settings) }
      guard settings.mode == .custom, let usage = settings.usage else { return nil }
      let count = L10n.count(usage.requests, one: "%@ request", other: "%@ requests", zh: "")
      return usage.limitedAt == nil ? (count, false) : ("\(count), daily mailbox limit reached", true)
    }

    public static func relayRetirement(_ settings: RelaySettings) -> String? {
      guard AppLanguage.current == .en else { return RelaySettingsText.retirement(settings) }
      guard let date = settings.retiring.compactMap({ ViewerTime.parse($0.retireAt) }).max() else { return nil }
      return "The old mailbox will be kept until \(relayDate(date))."
    }

    private static func relayDate(_ date: Date) -> String {
      date.formatted(.dateTime.month(.abbreviated).day().locale(AppLanguage.en.locale()))
    }

    public static func relayFailure(_ status: Int?) -> String {
      guard AppLanguage.current == .en else { return RelaySettingsText.failure(status: status) }
      switch status {
      case 0: return "Can't reach the background service. Try again shortly."
      case 400: return "Enter a valid address for a Tacit relay mailbox."
      case 403: return "Check the activation code and try again."
      case 429: return "The mailbox reached its daily request limit. Try again tomorrow."
      case 502: return "Can't reach the mailbox. Check the address and your network."
      case 503: return "The background service is busy. Try again shortly."
      case 507: return "The mailbox is full. Free up space and try again."
      default: return "The mailbox operation failed. Try again shortly."
      }
    }
  }
}
