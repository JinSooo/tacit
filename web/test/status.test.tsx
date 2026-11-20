import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { StatusContent } from "../src/status-view.tsx";
import type { HubStatus } from "../src/status.ts";

const generated_at = "2026-11-12T02:03:00Z";
const total = { calls: 0, ok: 0, failed: 0, ms: 0, input_tokens: null, output_tokens: null, input_tokens_incomplete: false, output_tokens_incomplete: false };
function emptyStatus(): HubStatus {
  return {
    generated_at,
    hub: { started_at: generated_at, uptime_s: 0, pid: 10, bun: null, schema_version: 12,
      busy: { since: generated_at, total: 0, by_route: { ingest: 0, agent: 0, web: 0 }, last_at: null } },
    listen: { host: "127.0.0.1", port: 47823, localhost_only: true },
    database: { file: "synthetic/history.db", bytes: 0 },
    records: { total: 0, tombstones: 0, by_source: [], by_device: [] },
    distill: {
      enabled_at: null, heartbeat_at: null, last_round_at: null, last_slow_round_at: null, cursor_at: null, backfill_done: false,
      frames: {}, threads: {}, needs_regen: { threads: 0, projects: 0, days: 0 }, pending_open: {},
      requests: { total: 0, by_status: {}, recent: [] }, last_error: null, last_ok_at: null, cooldown: null,
    },
    collector: null,
    llm_today: { date: "2026-11-12", total, by_tier: [], used_tokens: 0, token_limit: null },
    agent_reads_today: 0,
    audio: { transcription: null, transcription_disabled: false, speakers: {}, voice_conversations: 0, sample_requests_open: 0, deletes_pending: 0 },
  };
}
const render = (status: HubStatus) => renderToStaticMarkup(<StatusContent status={status} />);

test("后台拥堵出现后才显示重试次数；样本队列为空只说没有待上传", () => {
  const status = emptyStatus();
  const empty = render(status);
  expect(empty).not.toContain("后台服务忙，自动重试");
  expect(empty).toContain("没有待上传的试听样本");
  expect(empty).not.toContain("都已上传");
  const last_at = "2026-11-12T02:00:00Z";
  status.hub.busy = { ...status.hub.busy, total: 12, last_at };
  status.audio.sample_requests_open = 2;
  const active = render(status);
  expect(active).toContain("后台服务忙，自动重试");
  expect(active).toContain("启动以来 12 次");
  expect(active).toContain(`dateTime="${last_at}"`);
  expect(active).toContain("2 个在等设备上传");
  for (const html of [empty, active]) {
    expect(html).not.toContain("503");
    expect(html).not.toContain("中枢");
  }
});

test("本机转写区分关闭和状态缺失，并注明队列积压、丢弃和更新时间", () => {
  const status = emptyStatus();
  expect(render(status)).toContain("<dt>转写队列（本机）</dt><dd>没有本机采集端状态</dd>");
  status.audio.transcription_disabled = true;
  expect(render(status)).toContain("<dt>转写队列（本机）</dt><dd>录音未开启</dd>");

  const update = { updated_at: "2026-11-12T02:00:00Z", stale: true };
  status.audio.transcription_disabled = false;
  status.audio.transcription = { pending: 4, failed: 1, ...update };
  status.collector = { outbox_bytes: 1024, outbox_dropped: 2, outbox_degraded: false, ...update };
  const stale = render(status);
  expect(stale).toContain("<dt>转写队列（本机）</dt><dd>待转写 4 段，失败 1 段");
  expect(stale.match(/采集端 3 分钟没更新/g)).toHaveLength(2);
  expect(stale).toContain('<span class="error">1.0 KB，本次运行已丢弃 2 条</span>');

  status.collector = { outbox_bytes: 0, outbox_dropped: 0, outbox_degraded: true, updated_at: generated_at, stale: false };
  expect(render(status)).toContain('<span class="error">0 B，待发送队列异常</span>');
});

test("整理区显示手动进度、中文错误类别、模型暂停及同类恢复", () => {
  const status = emptyStatus();
  const until = "2026-11-12T02:20:00Z";
  status.distill.cooldown = { until, kind: "rate_limited" };
  status.distill.last_error = { at: generated_at, tier: "minute", error: "timeout", recovered: false };
  status.distill.requests = { total: 2, by_status: { running: 1, failed: 1 }, recent: [
    { id: "a", status: "running", done: 1, total: 5, error: null, created_at: generated_at, updated_at: generated_at },
    { id: "b", status: "failed", done: 1, total: 3, error: "合成错误原文", created_at: generated_at, updated_at: generated_at },
  ] };
  const unrecovered = render(status);
  expect(unrecovered).toContain("进行中，已处理 1/5");
  expect(unrecovered).toContain("失败，已处理 1/3");
  expect(unrecovered).toContain("未知错误");
  expect(unrecovered).not.toContain("合成错误原文");
  expect(unrecovered).toMatch(/模型暂停调用到 <time dateTime="[^"]+">\d\d:\d\d<\/time>（原因：请求太频繁）/);
  expect(unrecovered).toContain("超时");
  expect(unrecovered).not.toContain("已恢复");

  status.distill.last_error.recovered = true;
  status.distill.requests.recent[1]!.error = "server_error:503";
  status.distill.cooldown = null;
  const recovered = render(status);
  expect(recovered).toContain("同类调用之后已恢复");
  expect(recovered).toContain("服务出错");
  expect(recovered).not.toContain("server_error:503");
  expect(recovered).not.toContain("模型暂停调用到");
});

test("模型用量只标注缺失 token 的格，区分部分已知和全未知", () => {
  const status = emptyStatus();
  const usage = { calls: 2, ok: 1, failed: 1, ms: 1200, input_tokens: 30, output_tokens: 12, input_tokens_incomplete: true, output_tokens_incomplete: false };
  status.llm_today = { ...status.llm_today, used_tokens: 42, total: { ...usage, calls: 3, ok: 2, output_tokens_incomplete: true }, by_tier: [
    { ...usage, tier: "minute", models: ["example"] },
    { ...usage, tier: "hour", models: ["example"], calls: 1, failed: 0, input_tokens: null, output_tokens: null, output_tokens_incomplete: true },
  ] };
  const html = render(status);
  expect(html).toContain('data-label="输入">30<span class="muted">（部分未知）</span></td>');
  expect(html).toContain('data-label="输出">12</td>');
  expect(html).toContain('data-label="输入">未知</td>');
  expect(html).toContain('data-label="输出">12<span class="muted">（部分未知）</span></td>');
});

test("模型用量显示今天已用与上限，用量冷却说明次日零点恢复", () => {
  const status = emptyStatus();
  expect(render(status)).toContain("今天已用 0 token / 上限 不限");
  status.llm_today.used_tokens = 10_500;
  status.llm_today.token_limit = 10_000;
  status.distill.cooldown = { kind: "budget", until: "2026-11-13T00:00:00+09:00" };
  const html = render(status);
  expect(html).toContain("今天已用 10,500 token / 上限 10,000 token");
  expect(html).toContain("已达到今天的用量上限，明天 0 点恢复");
});
