/** 只匹配消息开头的协议标记，避免误删用户在正文中讨论这些标记的文字。 */
export const injectionRules = [
  { name: "command", pattern: /^<(?:command-[\w-]+|local-command-[\w-]+|bash-input|bash-stdout|bash-stderr)(?:\s|>)/, reason: "命令展开及本机 shell 输出不是用户亲自输入的对话。" },
  { name: "task", pattern: /^<(?:task-notification|subagent_notification|agent|heartbeat|happy-system|conversation_history)(?:\s|>)/, reason: "后台任务、子 Agent、心跳和恢复历史属于机器注入。" },
  { name: "skill", pattern: /^(?:Base directory for this skill:|<skill(?:\s|>)|<skills_instructions>|## Skills\s)/, reason: "技能正文由工具载入，不是用户输入。" },
  { name: "summary", pattern: /^(?:This session is being continued from a previous conversation|The conversation so far has been summarized)/, reason: "压缩摘要是对旧消息的自动复述。" },
  { name: "interrupted", pattern: /^(?:\[Request interrupted|<turn_aborted>)/, reason: "中断提示是客户端状态。" },
  { name: "automation", pattern: /^You are running an automation(?:\.|\s)/, reason: "自动化调度提示并非用户当次输入。" },
  { name: "orchestrator", pattern: /^(?:Delegated task node:|\[T3 Code: (?:scheduled task|the agent in T3 thread)|\[SYSTEM NOTIFICATION - NOT USER INPUT\])/, reason: "编排器转来的子任务结果、定时任务和系统通知不是用户亲自输入（2026-11-24 曾被当成用户原话出现在时间线草稿里）。" },
];

/** 可与真正的用户正文共存的注入块，只剥去块本身。 */
export const injectedBlockRules = [
  { name: "reminder", tag: "system-reminder", reason: "系统提醒伪装在 user 内容中。" },
  { name: "environment", tag: "environment_context", reason: "工作目录和权限等环境信息不是对话。" },
  { name: "instructions", tag: "user_instructions", reason: "持久指令由客户端注入。" },
  { name: "agents", tag: "INSTRUCTIONS", reason: "AGENTS.md 正文是项目指令，不是当次用户输入。" },
  { name: "hook", tag: "hook-output|hook_output|hook-context|hook_context|hook-additional-context", reason: "hook 的输出来自程序。" },
  { name: "tool-result", tag: "tool_result", reason: "工具输出即使被包在文本里也不属于对话。" },
  { name: "plugin-catalog", tag: "recommended_plugins", reason: "可安装插件目录由客户端附带。" },
  { name: "browser", tag: "external_codex_apps_open_page|external_browser_tabs|in-app-browser-context|external_codex_apps_selected_page_part_\\d+_of_\\d+", reason: "浏览器自动附带的页面上下文不是用户输入。" },
];

export const eventExclusionRules = [
  { name: "event-type", reason: "仅接受 Claude user/assistant 和 Codex response_item.message，忽略工具、统计及 event_msg 的重复副本。" },
  { name: "role", reason: "system/developer/tool 角色不是双方可见的对话。" },
  { name: "block-type", reason: "仅接受 text/input_text/output_text；图片、tool_result、tool_use、thinking、reasoning 全部忽略。" },
  { name: "claude-meta", reason: "isMeta、isCompactSummary、系统来源、hook、任务通知和 sidechain 表示自动上下文或子 Agent 对话。" },
  { name: "codex-recipient", reason: "发给工具的 assistant 消息与 analysis 通道不是可见回复。" },
];

/** 不整条丢弃的协议包装：保留其中或其后的真实用户文字。 */
export const textTransformRules = {
  image: { pattern: /^(?:\[Image:[^\]\n]*\]|<image\b[^>]*>)\s*/g, reason: "图片占位只有附件名字和路径，不属于文字对话。" },
  reply: { pattern: /^<send_user_message_question_reply>([\s\S]*)<\/send_user_message_question_reply>$/, reason: "澄清回答包装中只有 answer 是用户输入，问题和内部标识丢弃。" },
};

/** 客户端包装的澄清回答只保留 answer，剥去 AI 问题和内部标识。 */
export function cleanUserText(text: string): string {
  let value = text.trim();
  // 桌面附件清单不是问题正文。只识别完整客户端包装，保留 My request 后的实际输入。
  if (value.startsWith("# Files mentioned by the user:")) {
    const marker = /^## My request:\s*$/m.exec(value);
    if (marker) value = value.slice(marker.index + marker[0].length).replace(/(?:\n\s*<\/image>)+\s*$/, "").trim();
  }
  const reply = value.match(textTransformRules.reply.pattern);
  if (reply) {
    try {
      const answers: unknown = JSON.parse(reply[1]!);
      return Array.isArray(answers) ? answers.flatMap(item => typeof item?.answer === "string" ? [item.answer.trim()] : []).filter(Boolean).join("\n") : "";
    } catch { return ""; }
  }
  if (injectionRules.some(rule => rule.pattern.test(value))) return "";
  // 指令标题也由客户端生成；保留关闭标签之后可能追加的真实问题。
  value = value.replace(/^# AGENTS\.md instructions for[^\n]*\n\s*(?=<INSTRUCTIONS>)/, "");
  // 重复到稳定，处理无换行拼接且标签顺序不同的上下文块。
  let previous: string;
  do {
    previous = value;
    for (const { tag } of injectedBlockRules) {
      value = value.replace(new RegExp(`(^|\\n)[ \\t]*(?:(?:Human|User):[ \\t]*)?<(${tag})(?:\\s[^>]*)?>[\\s\\S]*?<\\/\\2>[ \\t]*`, "g"), "$1");
      // 未闭合的注入块也不输出。
      const leading = value.trim();
      if (new RegExp(`^<(${tag})(?:\\s|>)`).test(leading)) {
        const next = leading.replace(new RegExp(`^<(${tag})(?:\\s[^>]*)?>[\\s\\S]*?<\\/\\1>\\s*`), "");
        if (next === leading) return "";
        value = next;
      }
    }
    // 图片占位仅包含名字和路径；保留其后的真实输入。
    value = value.replace(textTransformRules.image.pattern, "").trim();
  } while (value !== previous);
  return injectionRules.some(rule => rule.pattern.test(value)) ? "" : value;
}
