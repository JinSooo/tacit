import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { BusyStatus } from "../src/status-view.tsx";

test("状态页库忙重试始终显示累计次数，发生后显示最近一次时间", () => {
  const busy = { since: "2026-11-12T01:00:00Z", total: 0, by_route: { ingest: 0, agent: 0, web: 0 }, last_at: null as string | null };
  const empty = renderToStaticMarkup(<BusyStatus busy={busy} />);
  expect(empty).toContain("库忙重试");
  expect(empty).toContain("启动以来 0 次");
  expect(empty).toContain("最近一次 尚未发生");
  const last_at = "2026-11-12T02:00:00Z";
  const active = renderToStaticMarkup(<BusyStatus busy={{ ...busy, total: 12, last_at }} />);
  expect(active).toContain("启动以来 12 次");
  expect(active).toContain(`dateTime="${last_at}"`);
  expect(active).not.toContain("尚未发生");
  for (const html of [empty, active]) {
    expect(html).not.toContain("503");
    expect(html).not.toContain("中枢");
  }
});
