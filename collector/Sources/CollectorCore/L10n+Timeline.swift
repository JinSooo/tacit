import Foundation

public extension L10n {
  static var hideSidebar: String { text(zh: "隐藏侧栏", en: "Hide sidebar") }
  static var showSidebar: String { text(zh: "显示侧栏", en: "Show sidebar") }
  static var remove: String { text(zh: "移除", en: "Remove") }
  static var cancel: String { text(zh: "取消", en: "Cancel") }
  static var projectRemovalExplanation: String { text(zh: "原始记录不会删除。这个目录以后不再自动识别为项目，AI 工具也查不到它的进展。", en: "Original records are kept. This folder will no longer be recognized as a project, and AI tools won't see its progress.") }
  static var expanded: String { text(zh: "已展开", en: "Expanded") }
  static var collapsed: String { text(zh: "已折叠", en: "Collapsed") }
  static var timeline: String { text(zh: "时间线", en: "Timeline") }
  static var search: String { text(zh: "搜索", en: "Search") }
  static var project: String { text(zh: "项目", en: "Project") }
  static var earlier: String { text(zh: "更早", en: "Earlier") }
  static var removeProject: String { text(zh: "移除项目…", en: "Remove project…") }
  static var pauseRecording: String { text(zh: "暂停记录", en: "Pause recording") }
  static var grantAccess: String { text(zh: "授权…", en: "Grant access…") }
  static var permissionNeeded: String { text(zh: "需要授权", en: "Permission needed") }
  static var cantReachBackgroundService: String { text(zh: "连不上后台服务", en: "Can't reach background service") }
  static var accessibilityPermission: String { text(zh: "辅助功能权限", en: "Accessibility permission") }
  static var allSourcesAreOff: String { text(zh: "所有数据源都已关闭", en: "All sources are off") }
  static var refresh: String { text(zh: "刷新", en: "Refresh") }
  static var jumpToDate: String { text(zh: "跳到日期", en: "Jump to date") }
  static var datePickerAccessibility: String { text(zh: "", en: "Choose date") }
  static var chooseDate: String { text(zh: "选择日期", en: "Choose date") }
  static var previousDay: String { text(zh: "前一天", en: "Previous day") }
  static var today: String { text(zh: "今天", en: "Today") }
  static var nextDay: String { text(zh: "后一天", en: "Next day") }
  static var previousMonth: String { text(zh: "上个月", en: "Previous month") }
  static var nextMonth: String { text(zh: "下个月", en: "Next month") }
  static var backToToday: String { text(zh: "回到今天", en: "Today") }
  static var simple: String { text(zh: "简约", en: "Simple") }
  static var detailed: String { text(zh: "详细", en: "Detailed") }
  static var lastSummaryFailed: String { text(zh: "最近一次整理失败", en: "Last summary failed") }
  static var loadingTimeline: String { text(zh: "正在读取时间线", en: "Loading timeline…") }
  static var noRecordsForThisDay: String { text(zh: "这一天没有记录", en: "No records for this day") }
  static var activitiesForThisDay: String { text(zh: "这一天的活动", en: "Activities for this day") }
  static var noDaySummary: String { text(zh: "这一天的记录还没有可展示的整理结果", en: "No summary to show for this day") }
  static var dayHasOriginalRecords: String { text(zh: "这一天有原始记录", en: "Original records are available for this day") }
  static var noDayTimeline: String { text(zh: "这一天还没有时间线", en: "No timeline for this day yet") }
  static var summarizing: String { text(zh: "正在整理", en: "Summarizing…") }
  static var allRecordsForThisDay: String { text(zh: "这一天的全部记录", en: "All records for this day") }
  static var comma: String { text(zh: "，", en: ", ") }
  static var taskHistoryAndEvidence: String { text(zh: "经过与依据", en: "Task history and evidence") }
  static var timelineItemUpdated: String { text(zh: "这件事已更新，可返回查看当天的时间线", en: "This task has been updated. Go back to view the day's timeline.") }
  static var collapseOriginalRecords: String { text(zh: "收起原始记录", en: "Collapse original records") }
  static var expandOriginalRecords: String { text(zh: "展开原始记录", en: "Expand original records") }
  static var listSeparator: String { text(zh: "、", en: ", ") }
  static var retry: String { text(zh: "重试", en: "Retry") }
  static var loadingOriginalRecords: String { text(zh: "正在读取原始记录", en: "Loading original records…") }
  static var taskHistory: String { text(zh: "这件事的经过", en: "Task history") }
  static var thisActivityIsWrong: String { text(zh: "这段写得不对", en: "This activity is wrong") }
  static var delete: String { text(zh: "删除", en: "Delete") }
  static var deleteThisActivitysRecords: String { text(zh: "删除这段记录？", en: "Delete this activity's records?") }
  static var activityDescription: String { text(zh: "这段活动的描述", en: "Activity description") }
  static var saving: String { text(zh: "正在保存…", en: "Saving…") }
  static var save: String { text(zh: "保存", en: "Save") }
  static var managingDeviceConnected: String { text(zh: "有一台新的管理设备已连接", en: "A new managing device connected") }
  static var devicePermissionsChanged: String { text(zh: "另一台设备修改了设备权限", en: "Another device changed device permissions") }
  static var modelKeyChanged: String { text(zh: "另一台设备修改了 AI 模型的密钥", en: "Another device changed an AI model key") }
  static var acknowledgeFailed: String { text(zh: "暂时无法确认，请重试。", en: "Couldn't acknowledge. Try again.") }
  static var gotIt: String { text(zh: "知道了", en: "Got it") }
  static var searchTimelineAndRecords: String { text(zh: "搜索时间线和记录", en: "Search timeline and records") }
  static var clearSearch: String { text(zh: "清除搜索", en: "Clear search") }
  static var searching: String { text(zh: "正在搜索", en: "Searching…") }
  static var loadMoreResults: String { text(zh: "加载更多结果", en: "Load more results") }
  static var noMatchingActivitiesOrRecords: String { text(zh: "没有找到匹配的活动或记录。", en: "No matching activities or records.") }
  static var goToTimeline: String { text(zh: "转到时间线", en: "Go to timeline") }
  static var hideDetails: String { text(zh: "隐藏详情", en: "Hide details") }
  static var noRecordsMatchTheFilters: String { text(zh: "没有符合筛选的记录", en: "No records match the filters") }
  static var clearThisFilter: String { text(zh: "清除这个筛选", en: "Clear this filter") }
  static var source: String { text(zh: "来源", en: "Source") }
  static var allSources: String { text(zh: "全部来源", en: "All sources") }
  static var device: String { text(zh: "设备", en: "Device") }
  static var allDevices: String { text(zh: "全部设备", en: "All devices") }
  static var filter: String { text(zh: "筛选", en: "Filter") }
  static var addANote: String { text(zh: "补写一条记录", en: "Add a note") }
  static var activeTimeHelp: String { text(zh: "活跃时长按记录覆盖的时段算，几个来源同时在记录只算一次", en: "Active time counts overlapping records only once") }
  static var screenText: String { text(zh: "截图识字", en: "Screen text") }
  static var secretsHidden: String { text(zh: "已隐去密钥", en: "Secrets hidden") }
  static var privateRecordHelp: String { text(zh: "私密：不交给 AI 整理", en: "Private: excluded from AI summaries") }
  static var includesPrivateRecords: String { text(zh: "含私密记录", en: "Includes private records") }
  static var unsummarizedActivity: String { text(zh: "这段还没整理，整理后会写出在做什么。", en: "This activity hasn't been summarized yet.") }
  static var app: String { text(zh: "应用", en: "App") }
  static var andOthers: String { text(zh: " 等", en: " and others") }
  static var shortActivitiesHelp: String { text(zh: "每段不到 2 分钟、还没整理的活动，折在一起", en: "Groups unsummarized activities shorter than 2 minutes") }
  static var notOnTimeline: String { text(zh: "未入时间线", en: "Not on timeline") }
  static var notOnTimelineHelp: String { text(zh: "包含因当天活动段数达到上限而留在原始列表里的记录", en: "Includes records left out when the daily timeline reached its activity limit") }
  static var zoomToSelection: String { text(zh: "放大到选区", en: "Zoom to selection") }
  static var showWholeDay: String { text(zh: "看整天", en: "Show whole day") }
  static var inProgress: String { text(zh: "正在推进", en: "In progress") }
  static var recentProgress: String { text(zh: "最近的进展", en: "Recent progress") }
  static var more: String { text(zh: "更多", en: "More") }
  static var noTasksInProgress: String { text(zh: "现在没有正在推进的事。", en: "No tasks in progress.") }
  static var newSessionsGetContextForTheseTasks: String { text(zh: "AI 工具查项目进展时会看到这几件事。", en: "AI tools see these tasks when they check project progress.") }
  static var loadingTasksInProgress: String { text(zh: "正在读取正在推进的事", en: "Loading tasks in progress…") }
  static var noSummaryToShowForThisProject: String { text(zh: "这个项目还没有可展示的整理结果。", en: "No summary to show for this project.") }
  static var loadEarlierDays: String { text(zh: "加载更早的日期", en: "Load earlier days") }
  static var loadingProjectProgress: String { text(zh: "正在读取项目进展", en: "Loading project progress…") }
  static var collapseTaskHistory: String { text(zh: "收起这件事的经过", en: "Collapse task history") }
  static var expandTaskHistory: String { text(zh: "展开这件事的经过", en: "Expand task history") }
  static var whatAIRemembers: String { text(zh: "AI 记住的要点", en: "What AI remembers") }
  static var loadingTaskHistory: String { text(zh: "正在读取这件事的经过", en: "Loading task history…") }
  static var noHistoryToShowForThisTask: String { text(zh: "这件事还没有可展示的经过。", en: "No history to show for this task.") }
  static var taskInProgress: String { text(zh: "进行中", en: "In progress") }
  static var paused: String { text(zh: "已暂停", en: "Paused") }
  static var done: String { text(zh: "已完成", en: "Done") }
  static var dropped: String { text(zh: "不做了", en: "Dropped") }
  static var archived: String { text(zh: "已归档", en: "Archived") }
  static var personal: String { text(zh: "生活", en: "Personal") }
  static var taskSessionHelp: String { text(zh: "隔 30 分钟以上再回来做，算新的一次", en: "Returning after a break of more than 30 minutes counts as a new session") }
  static var startedToday: String { text(zh: "今天开始", en: "Started today") }
  static var task: String { text(zh: "事项", en: "Task") }
  static var level: String { text(zh: "层级", en: "Level") }
  static var brief: String { text(zh: "简略", en: "Brief") }
  static var basedOn: String { text(zh: "依据", en: "Based on") }
  static var noBriefYet: String { text(zh: "还没有简略版", en: "No brief yet") }
  static var progress: String { text(zh: "进展", en: "Progress") }
  static var goal: String { text(zh: "目标", en: "Goal") }
  static var people: String { text(zh: "相关的人", en: "People") }
  static var links: String { text(zh: "链接", en: "Links") }
  static var files: String { text(zh: "文件", en: "Files") }
  static var commands: String { text(zh: "命令", en: "Commands") }
  static var related: String { text(zh: "相关", en: "Related") }
  static var copyCommand: String { text(zh: "复制命令", en: "Copy command") }
  static var openAction: String { text(zh: "打开", en: "Open") }
  static var collapse: String { text(zh: "收起", en: "Collapse") }
  static var writtenByYou: String { text(zh: "你写的", en: "Written by you") }
  static var thisIsWrong: String { text(zh: "这条不对", en: "This is wrong") }
  static var removing: String { text(zh: "正在移出…", en: "Removing…") }
  static var doesntBelongHere: String { text(zh: "不属于这里", en: "Doesn't belong here") }
  static var thisIsWrongAction: String { text(zh: "这条不对…", en: "This is wrong…") }
  static var doesntBelongHereAction: String { text(zh: "不属于这里…", en: "Doesn't belong here…") }
  static var removeThisFromTheTask: String { text(zh: "这条内容不属于这件事项？", en: "Remove this from the task?") }
  static var removeAction: String { text(zh: "移出", en: "Remove") }
  static var missingSupportingRecords: String { text(zh: "找不到依据记录，可能已经删除", en: "Supporting records may have been deleted") }
  static var confidenceUnknown: String { text(zh: "把握未知", en: "Confidence unknown") }
  static var modelConfidenceHelp: String { text(zh: "模型对这条推测有几成把握", en: "How certain the model is about this inference") }
  static var noSupportingRecordsYet: String { text(zh: "还没有依据记录", en: "No supporting records yet") }
  static var replacement: String { text(zh: "改成", en: "Replacement") }
  static var factCorrectionExplanation: String { text(zh: "依据和归属不变，以后显示你写的这句。", en: "Your wording will be shown with the existing task and supporting records.") }
  static var correcting: String { text(zh: "正在修正…", en: "Correcting…") }
  static var correct: String { text(zh: "修正", en: "Correct") }
  static var back: String { text(zh: "返回", en: "Back") }
  static var hideOriginal: String { text(zh: "收起原文", en: "Hide original") }
  static var showOriginal: String { text(zh: "查看原文", en: "Show original") }
  static var original: String { text(zh: "原文", en: "Original") }
  static var recordingContext: String { text(zh: "记录时的情况", en: "Recording context") }
  static var showInFinder: String { text(zh: "在访达中显示", en: "Show in Finder") }
  static var window: String { text(zh: "窗口", en: "Window") }
  static var url: String { text(zh: "网址", en: "URL") }
  static var repository: String { text(zh: "仓库", en: "Repository") }
  static var folder: String { text(zh: "目录", en: "Folder") }
  static var conversation: String { text(zh: "会话", en: "Conversation") }
  static var location: String { text(zh: "地点", en: "Location") }
  static var commit: String { text(zh: "提交", en: "Commit") }
  static var fileCount: String { text(zh: "文件数", en: "File count") }
  static var linesAdded: String { text(zh: "新增行", en: "Lines added") }
  static var linesDeleted: String { text(zh: "删除行", en: "Lines deleted") }
  static var author: String { text(zh: "作者", en: "Author") }
  static var downloadSource: String { text(zh: "下载来源", en: "Download source") }
  static var size: String { text(zh: "大小", en: "Size") }
  static var browserProfile: String { text(zh: "浏览器配置", en: "Browser profile") }
  static var exitCode: String { text(zh: "退出码", en: "Exit code") }
  static var duration: String { text(zh: "耗时", en: "Duration") }
  static var attendees: String { text(zh: "参会人", en: "Attendees") }
  static var calendar: String { text(zh: "日历", en: "Calendar") }
  static var windowText: String { text(zh: "读取窗口文字", en: "Window text") }
  static var databaseRead: String { text(zh: "读取数据库", en: "Database read") }
  static var systemAPI: String { text(zh: "系统接口", en: "System API") }
  static var fileRead: String { text(zh: "读取文件", en: "File read") }
  static var terminalHook: String { text(zh: "终端钩子", en: "Terminal hook") }
  static var speechToText: String { text(zh: "语音转文字", en: "Speech to text") }
  static var note: String { text(zh: "手动补写", en: "Note") }
  static var captureMethod: String { text(zh: "怎么记的", en: "Capture method") }
  static var redactedSecrets: String { text(zh: "隐去的密钥", en: "Secrets hidden") }
  static var copied: String { text(zh: "已复制", en: "Copied") }
  static var copy: String { text(zh: "复制", en: "Copy") }
  static var deleteThisRecord: String { text(zh: "删除这条记录？", en: "Delete this record?") }
  static var recordDeletionExplanation: String { text(zh: "删除后不能恢复。已经交给云端 AI 的内容收不回来。", en: "Deletion is permanent. Any content already sent to cloud AI services stays there.") }
  static var thisRecordHasNoText: String { text(zh: "这条没有正文", en: "This record has no text") }
  static var showAll: String { text(zh: "展开全部", en: "Show all") }
  static var correctThisRecord: String { text(zh: "修正这条记录", en: "Correct this record") }
  static var recordCorrectionExplanation: String { text(zh: "原文会保留，以后显示和整理都用你改的版本。", en: "The original is saved. Your version will be shown and used in future summaries.") }
  static var start: String { text(zh: "开始", en: "Start") }
  static var setAnEndTime: String { text(zh: "持续了一段时间", en: "Set an end time") }
  static var end: String { text(zh: "结束", en: "End") }
  static var title: String { text(zh: "标题", en: "Title") }
  static var whatDidYouDo: String { text(zh: "做了什么", en: "What did you do?") }
  static var addMoreDetailHere: String { text(zh: "想多写点可以写在这里", en: "Add more detail here") }
  static var noReadableTranscript: String { text(zh: "没有转出能读的内容", en: "No readable transcript") }
  static var conversationContent: String { text(zh: "对话内容", en: "Conversation") }
  static var hideOriginalTranscript: String { text(zh: "收起转写原文", en: "Hide original transcript") }
  static var showOriginalTranscript: String { text(zh: "查看转写原文", en: "Show original transcript") }
  static var theSummaryWillAppearLater: String { text(zh: "总结稍后生成", en: "The summary will appear later") }
  static var privateConversation: String { text(zh: "私密内容不生成总结", en: "Private content is excluded from summaries") }
  static var pendingExplanation: String { text(zh: "这些是需要你确认的事。不处理也没关系，记录和整理照常进行。", en: "Recording and summaries continue while these items await confirmation.") }
  static var showingCachedPending: String { text(zh: "连不上后台服务，下面是上次读到的内容。", en: "Can't reach the background service. Showing the last available data.") }
  static var nothingToConfirm: String { text(zh: "没有要确认的事", en: "Nothing to confirm") }
  static var pendingEmptyExplanation: String { text(zh: "拿不准的事会放在这里问你。", en: "Items that need your confirmation will appear here.") }
  static var toConfirm: String { text(zh: "待确认", en: "To confirm") }
  static var whoseVoiceIsThis: String { text(zh: "这是谁的声音", en: "Whose voice is this?") }
  static var newProject: String { text(zh: "新项目", en: "New project") }
  static var areTheseTheSameProject: String { text(zh: "是同一个项目吗", en: "Are these the same project?") }
  static var whoIsThis: String { text(zh: "这是谁？", en: "Who is this?") }
  static var whatsTheProjectCalled: String { text(zh: "项目叫什么？", en: "What's the project called?") }
  static var name: String { text(zh: "名字", en: "Name") }
  static var projectName: String { text(zh: "项目名", en: "Project name") }
  static var confirm: String { text(zh: "确定", en: "Confirm") }
  static var newVoice: String { text(zh: "新的声音", en: "New voice") }
  static var samplePending: String { text(zh: "试听片段还在路上，录到它的设备连上后就能听。", en: "The sample will be available when the device that recorded it connects.") }
  static var sampleExpired: String { text(zh: "录音已经过了保留期，听不到了。", en: "The recording expired and can no longer be played.") }
  static var unnamedProject: String { text(zh: "未命名项目", en: "Unnamed project") }
  static var openTask: String { text(zh: "打开这件事项", en: "Open task") }
  static var itsMe: String { text(zh: "是我", en: "It's me") }
  static var enterAName: String { text(zh: "填名字", en: "Enter a name") }
  static var enterThisPersonsName: String { text(zh: "这是别人，填上他的名字", en: "Enter this person's name") }
  static var matchAnExistingPerson: String { text(zh: "是已有的人", en: "Match an existing person") }
  static var unconfirmedVoices: String { text(zh: "还没确认的声音", en: "Unconfirmed voices") }
  static var matchVoiceHelp: String { text(zh: "这个声音和已有的某个人是同一个人", en: "Match this voice to someone already listed") }
  static var ignore: String { text(zh: "忽略", en: "Ignore") }
  static var ignoreVoiceHelp: String { text(zh: "以后不再问这个声音", en: "Stop asking about this voice") }
  static var confirmProject: String { text(zh: "是个项目", en: "Confirm project") }
  static var rename: String { text(zh: "改名…", en: "Rename…") }
  static var mergeIntoExistingProject: String { text(zh: "并入已有项目", en: "Merge into existing project") }
  static var dismissProject: String { text(zh: "不是项目", en: "Dismiss project") }
  static var markDone: String { text(zh: "做完了", en: "Mark done") }
  static var keepInProgress: String { text(zh: "还在做", en: "Keep in progress") }
  static var merge: String { text(zh: "合并", en: "Merge") }
  static var keepSeparate: String { text(zh: "保持分开", en: "Keep separate") }
  static var playSample: String { text(zh: "试听", en: "Play sample") }
  static var couldntLoadTheSample: String { text(zh: "取不到片段", en: "Couldn't load the sample") }
  static var couldntPlayTheSample: String { text(zh: "播放失败", en: "Couldn't play the sample") }
  static var skipThisVersion: String { text(zh: "跳过这个版本", en: "Skip this version") }
  static var installUpdate: String { text(zh: "更新", en: "Update") }
  static var auditExplanation: String { text(zh: "内容链接查看的是当前记录；项目进展可查看当时给出的正文。", en: "Record links show current content. Project progress shows what was returned at the time.") }
  static var aiToolsHaventReadAnythingYet: String { text(zh: "AI 工具还没有读取过", en: "AI tools haven't read anything yet") }
  static var runLog: String { text(zh: "运行记录", en: "Run log") }
  static var tool: String { text(zh: "工具", en: "Tool") }
  static var all: String { text(zh: "全部", en: "All") }
  static var failed: String { text(zh: "失败", en: "Failed") }
  static var contextResultCountHelp: String { text(zh: "给出了几个项目和事项", en: "Number of projects and tasks returned") }
  static var readResultCountHelp: String { text(zh: "读到了几个项目、事项、事实或记录", en: "Number of projects, tasks, facts or records read") }
  static var nothingWasReturned: String { text(zh: "这次没有读到内容", en: "Nothing was returned") }
  static var hideSavedSessionContext: String { text(zh: "收起当时的内容", en: "Hide saved content") }
  static var showSavedSessionContext: String { text(zh: "查看当时的内容", en: "Show saved content") }
  static var loadingAccessibility: String { text(zh: "正在读取", en: "Loading…") }
  static var loading: String { text(zh: "正在读取…", en: "Loading…") }
  static var thisItemWasDeleted: String { text(zh: "这一项已经删除", en: "This item was deleted") }
  static var record: String { text(zh: "记录", en: "Record") }
  static var contextAfterCompaction: String { text(zh: "对话压缩后重新带入", en: "Session context restored after compaction") }
  static var contextAtSessionStart: String { text(zh: "新会话开始时带入", en: "Session context provided at start") }
  static var contextOnRequest: String { text(zh: "查看项目进展", en: "Checked project progress") }
  static var viewNow: String { text(zh: "查看此刻", en: "View Now") }
  static var searchRecords: String { text(zh: "搜索历史记录", en: "Search records") }
  static var viewTimeline: String { text(zh: "查看时间线", en: "View timeline") }
  static var addToRecords: String { text(zh: "添加到历史记录", en: "Add to records") }
  static var addedARecord: String { text(zh: "新添加一条", en: "Added a record") }
  static var alreadySaved: String { text(zh: "已经有了，没有重复添加", en: "Already saved") }
  static var appendedCorrection: String { text(zh: "内容变了，记成一条修正", en: "Saved changed content as a correction") }
  static var previouslyDeleted: String { text(zh: "以前删过，没有添加", en: "Previously deleted") }
  static var runLogType: String { text(zh: "运行记录类型", en: "Run log type") }
  static var modelSummaries: String { text(zh: "模型整理", en: "Model summaries") }
  static var aiToolReads: String { text(zh: "AI 工具读取", en: "AI tool reads") }
  static var backgroundActivity: String { text(zh: "后台运行", en: "Background activity") }
  static var callRetentionExplanation: String { text(zh: "正文在本机保存 7 天。删除任一历史记录时，所有调用正文会一并清空，时间和状态保留。", en: "Call content is saved locally for 7 days. Deleting any record clears all call content and keeps times and statuses.") }
  static var noModelCallsYet: String { text(zh: "还没有模型调用", en: "No model calls yet") }
  static var loadMore: String { text(zh: "加载更多", en: "Load more") }
  static var modelUnknown: String { text(zh: "模型未记录", en: "Model unknown") }
  static var closed: String { text(zh: "已收起", en: "Collapsed") }
  static var commandLineSnapshotExplanation: String { text(zh: "这是交给命令行工具的内容；工具内部附加的说明和网络请求不可见。", en: "This is what Tacit sent to the command-line tool. Instructions and requests added by that tool are hidden.") }
  static var apiSnapshotExplanation: String { text(zh: "这是交给模型服务的请求正文，认证凭据不在其中。", en: "This is the request body sent to the model service, with credentials excluded.") }
  static var savedSessionContext: String { text(zh: "当时给出的内容", en: "Saved content") }
  static var request: String { text(zh: "发送内容", en: "Request") }
  static var response: String { text(zh: "返回内容", en: "Response") }
  static var noResponseToShowYet: String { text(zh: "尚无可展示的返回内容。", en: "No response to show yet.") }
  static var backgroundService: String { text(zh: "后台服务", en: "Background service") }
  static var summaries: String { text(zh: "内容整理", en: "Summaries") }
  static var activityCapture: String { text(zh: "活动采集", en: "Activity capture") }
  static var backgroundLogExplanation: String { text(zh: "展示最近的结构化状态与计数。含原文的诊断行不会显示在这里。", en: "Shows recent statuses and counts. Diagnostic lines containing original text are hidden.") }
  static var emptyBackgroundLog: String { text(zh: "暂时没有可展示的运行状态", en: "No background activity to show yet") }
  static var contentNotFound: String { text(zh: "内容不存在", en: "Content not found") }
  static var recordNotFound: String { text(zh: "记录不存在", en: "Record not found") }
  static var unreadableDeviceConnection: String { text(zh: "连不上后台服务：设备连接信息读不出来", en: "Can't read the device connection details") }
  static var deviceConnectionUnavailable: String { text(zh: "连不上后台服务：设备连接不可用", en: "Device connection unavailable") }
  static var databaseBusyTryAgainShortly: String { text(zh: "数据库忙，稍后再试", en: "Database busy. Try again shortly.") }
  static var devicePermissionDenied: String { text(zh: "当前设备权限不足", en: "This device lacks permission") }
  static var responseTooLarge: String { text(zh: "响应过大，请缩小查询范围", en: "Response too large. Narrow the search.") }
  static var unreadableResponse: String {
    text(zh: "后台服务返回的内容读不懂，请重试。如果还是不行，请复制诊断信息发给我们。",
         en: "The background service returned an unreadable reply. Try again. If it still fails, copy the diagnostics and send them to us.")
  }
  static var serviceOffline: String { text(zh: "网络已断开，恢复连接后请重试。", en: "The network is disconnected. Reconnect and try again.") }
  static var serviceAccessExpired: String { text(zh: "访问权限不足或身份已失效，请检查连接设置。", en: "Access was denied or has expired. Check your connection settings.") }
  static var serviceFeatureUnavailable: String { text(zh: "这个版本的后台服务暂不支持此功能。", en: "This feature is unavailable in this version of the background service.") }
  static var serviceOperationInProgress: String { text(zh: "操作正在进行，请稍后再试。", en: "An operation is in progress. Try again shortly.") }
  static var backgroundServiceFailed: String { text(zh: "后台服务出错了，请稍后重试。", en: "The background service encountered an error. Try again shortly.") }
  static var localServiceRequired: String { text(zh: "需要连接这台 Mac 的后台", en: "Connect to this Mac's background service") }
  static var unreadableConnectionSettings: String { text(zh: "后台连接配置无法读取", en: "Can't read the connection settings") }
  static var remoteServiceUnavailable: String { text(zh: "远端后台连接不可用", en: "Remote background service unavailable") }
  static var directServiceRequired: String { text(zh: "需要直连远端后台才能读取这些内容", en: "Connect directly to the remote background service to read this content") }
  static var missingAccessToken: String { text(zh: "后台服务可能还没启动，请重启 Tacit。", en: "The background service may not have started. Restart Tacit.") }
  static var serviceTimedOut: String { text(zh: "后台服务没有响应", en: "The background service didn't respond") }
  static var errorSeparator: String { text(zh: "；", en: ", ") }
  static var recordSaveFailed: String { text(zh: "记录未写入，请重试", en: "Couldn't save the record. Try again.") }
}

public extension L10n {
  static func removeProjectPrompt(_ name: String) -> String {
    text(zh: "移除“\(name)”？", en: "Remove ‘\(name)’?")
  }

  static func unconfirmedProject(_ name: String) -> String {
    text(zh: "\(name)，还没确认", en: "\(name), unconfirmed")
  }

  static func sourceCount(_ n: Int) -> String {
    count(n, one: "%@ source", other: "%@ sources", zh: "\(n) 个数据源")
  }

  static func timelineCutoff(_ time: String, hasDrafts: Bool, failed: Bool) -> String {
    let label = hasDrafts ? text(zh: "已整理到", en: "Summarized up to") : text(zh: "内容截至", en: "Up to")
    let suffix = failed ? text(zh: "，最近一次整理失败", en: ", last summary failed") : ""
    return "\(label) \(time)\(suffix)"
  }

  static func recordCount(_ n: Int, grouped: Bool = true) -> String {
    count(n, one: "%@ record", other: "%@ records", zh: grouped ? "%@ 条记录" : "\(n) 条记录")
  }

  static func shortRecordCount(_ n: Int, grouped: Bool = false) -> String {
    count(n, one: "%@ record", other: "%@ records", zh: grouped ? "%@ 条" : "\(n) 条")
  }

  static func originalRecordCount(_ n: Int) -> String {
    count(n, one: "%@ original record", other: "%@ original records", zh: "%@ 条原始记录")
  }

  static func groupedRecords(_ n: Int) -> String {
    text(zh: "连续 \(n) 条同样的记录合成一行", en: "\(number(n)) consecutive identical records grouped in one row")
  }

  static func activityCount(_ n: Int) -> String {
    count(n, one: "%@ activity", other: "%@ activities", zh: "%@ 段活动")
  }

  static func shortActivityCount(_ n: Int) -> String {
    count(n, one: "%@ short activity", other: "%@ short activities", zh: "\(n) 段零碎活动")
  }

  static func startTime(_ time: String) -> String { text(zh: "开始 \(time)", en: "Started at \(time)") }
  static func activeTime(_ duration: String) -> String { text(zh: "活跃 \(duration)", en: "Active for \(duration)") }

  static func hourLabel(_ hour: Int, on day: Date, calendar: Calendar = .current) -> String {
    guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return "" }
    return clock(date, calendar: calendar)
  }

  static func expandRecords(_ n: Int) -> String {
    count(n, one: "Expand %@ original record", other: "Expand %@ original records", zh: "展开 \(n) 条原始记录")
  }

  static func appTotal(_ n: Int) -> String {
    count(n, one: "%@ app total", other: "%@ apps total", zh: "等 \(n) 个应用")
  }

  static func backgroundRecordCount(_ n: Int) -> String {
    count(n, one: "%@ more screen or browser record", other: "%@ more screen and browser records", zh: "另有 %@ 条屏幕和网页记录")
  }

  static func deletingActivityRecords(_ n: Int) -> String {
    count(n, one: "This permanently deletes %@ record from the activity.",
          other: "This permanently deletes all %@ records from the activity.", zh: "这段包含的 %@ 条记录会永久删除。")
  }

  static func startedOn(_ date: String) -> String { text(zh: "\(date)开始", en: "Started on \(date)") }

  static func sessionCount(_ n: Int) -> String {
    count(n, one: "%@ session", other: "%@ sessions", zh: "前后 \(n) 次")
  }

  static func factCount(_ n: Int) -> String {
    count(n, one: "%@ item", other: "%@ items", zh: "\(n) 条")
  }

  static func showFacts(_ n: Int) -> String { text(zh: "展开全部 \(n) 条", en: "Show all \(number(n))") }

  static func basedOnRecordCount(_ n: Int) -> String {
    count(n, one: "Based on %@ record", other: "Based on %@ records", zh: "依据 \(n) 条")
  }

  static func detachFactPrompt(_ n: Int) -> String {
    count(n, one: "This removes the item and the activity containing its %@ supporting record from this task. The next summary will reassign the activity.",
          other: "This removes the item and the activity containing its %@ supporting records from this task. The next summary will reassign the activity.",
          zh: "它和 \(n) 条依据所在的活动会从这件事项里移走，以后也不会再分回来。下次整理时会自动归到合适的地方。")
  }

  static func factKind(_ kind: String, chinese: String) -> String {
    text(zh: chinese, en: ["next": "Next steps", "open": "Open questions", "decision": "Decisions",
                          "inference": "Inferences", "rejected": "Rejected"][kind] ?? kind)
  }

  static func modelConfidence(_ percent: Int) -> String { text(zh: "把握 \(percent)%", en: "\(percent)% confidence") }
  static func captureConfidence(_ percent: Int) -> String { text(zh: "识别把握 \(percent)%", en: "\(percent)% recognition confidence") }

  static func redactionCount(_ n: Int) -> String {
    count(n, one: "%@ secret", other: "%@ secrets", zh: "\(n) 处")
  }

  static func showTurns(_ n: Int) -> String {
    count(n, one: "Show %@ turn", other: "Show all %@ turns", zh: "展开全部 %@ 段")
  }

  static func correctedAt(_ date: Date) -> String {
    let age = ViewerFormat.relative(date)
    return text(zh: age == "刚刚" ? "刚刚修正过" : "\(age)修正过", en: "Corrected \(age.lowercased())")
  }

  static func pendingCount(_ n: Int) -> String {
    count(n, one: "%@ item to confirm", other: "%@ items to confirm", zh: "%@ 个问题待确认")
  }

  static func spokeInConversations(_ n: Int, duration: String) -> String {
    count(n, one: "Spoke for \(duration) in %@ conversation", other: "Spoke for \(duration) across %@ conversations",
          zh: "\(n) 段对话里说了 \(duration)")
  }

  static func conversationCount(_ n: Int) -> String {
    count(n, one: "%@ conversation", other: "%@ conversations", zh: "\(n) 段对话")
  }

  static func updateAvailable(_ version: String) -> String {
    text(zh: "Tacit \(version) 可以更新了", en: "Update available for Tacit \(version)")
  }

  static func repeatedReads(_ n: Int) -> String {
    text(zh: "重复 \(n) 次", en: "Repeated \(number(n)) times")
  }

  static func groupedReads(_ n: Int) -> String {
    text(zh: "连续 \(n) 次相同的读取，点开逐次查看", en: "\(number(n)) consecutive identical reads. Expand to view each one.")
  }

  static func itemsRead(_ n: Int) -> String {
    count(n, one: "Read %@ item", other: "Read %@ items", zh: "读到 %@ 项")
  }

  static func bytesReturned(_ size: String) -> String { text(zh: "共返回 \(size)", en: "\(size) returned") }

  static func readAction(_ level: String) -> String {
    switch level {
    case "brief": text(zh: "读取简介", en: "Read brief")
    case "detail": text(zh: "读取详情", en: "Read details")
    case "evidence": text(zh: "读取依据", en: "Read supporting records")
    default: text(zh: "读取内容", en: "Read content")
    }
  }

  static func searchCharacters(_ rawCount: String) -> String {
    guard let n = Int(rawCount) else { return rawCount }
    return count(n, one: "Searched for %@ character", other: "Searched for %@ characters", zh: "搜了 \(rawCount) 个字")
  }

  static func hiddenSecrets(_ rawCount: String) -> String {
    guard let n = Int(rawCount) else { return rawCount }
    return count(n, one: "Hidden %@ secret", other: "Hidden %@ secrets", zh: "隐去了 \(rawCount) 处密钥")
  }

  static func callTokens(input: Int?, output: Int?) -> String {
    let unknown = text(zh: "未知", en: "unknown")
    let inputCount = input.map(number) ?? unknown
    let outputCount = output.map(number) ?? unknown
    let inputUnit = input == 1 ? "token" : "tokens"
    let outputUnit = output == 1 ? "token" : "tokens"
    return text(zh: "输入 \(inputCount) / 输出 \(outputCount) token",
                en: "\(inputCount.capitalized) input \(inputUnit), \(outputCount) output \(outputUnit)")
  }

  static func callStates(provider: String, validation: String) -> String {
    let returned: String
    switch provider {
    case "returned": returned = text(zh: "已返回", en: "returned")
    case "sending": returned = text(zh: "等待中", en: "waiting")
    default: returned = text(zh: "失败或未发送", en: "failed or unsent")
    }
    let result: String
    switch validation {
    case "passed": result = text(zh: "通过", en: "passed")
    case "failed": result = text(zh: "未通过", en: "failed")
    default: result = text(zh: "未记录", en: "unrecorded")
    }
    return text(zh: "返回：\(returned)　校验：\(result)", en: "Response \(returned), validation \(result)")
  }

  static func snapshotRedactions(_ n: Int) -> String {
    count(n, one: "%@ possible secret hidden.", other: "%@ possible secrets hidden.", zh: "已隐藏 \(n) 处可能的密钥。")
  }

  static func truncatedResponse(_ n: Int) -> String {
    text(zh: "返回内容（仅保留前 \(number(n)) 字符）", en: "First \(number(n)) characters of the response")
  }

  static func draftTitle(_ title: String, kind: String? = nil, lang: AppLanguage = .current) -> String {
    guard kind == "conversation" || title == "一场对话" else { return title }
    return text(zh: "一场对话", en: "Conversation", lang: lang)
  }

  private static let speakerPrefix = try! NSRegularExpression(
    pattern: #"(?m)^(?:\[\d{2}:\d{2}:\d{2}\][ \t]*)?(?:\[(我|AI)\]|(我|对方(?: *[0-9]+)?|其他人)[：:])"#
  )

  /// Localize stored speaker markers for display only and preserve the transcript text.
  static func transcript(_ original: String, lang: AppLanguage = .current) -> String {
    guard lang == .en else { return original }
    let result = NSMutableString(string: original)
    let matches = speakerPrefix.matches(in: original, range: NSRange(location: 0, length: result.length))
    for match in matches.reversed() {
      if match.range(at: 1).location != NSNotFound {
        let label = match.range(at: 1)
        result.replaceCharacters(in: label, with: speaker(result.substring(with: label), lang: lang))
      } else {
        let label = match.range(at: 2)
        var canonical = result.substring(with: label)
        if canonical.hasPrefix("对方"), let n = Int(canonical.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
          canonical = "对方 \(n)"
        }
        result.replaceCharacters(in: label, with: speaker(canonical, lang: lang))
      }
    }
    return result as String
  }
}
