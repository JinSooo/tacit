import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { HubDB } from "../../hub/src/db.ts";
import { validateRecord, type RecordV1 } from "../../packages/record/index.ts";
import { BROWSERS, cleanUrl, collectBrowserHistory, withDatabaseCopy, type Browser, type BrowserState } from "./main.ts";

const homes: string[] = [];
const databases: Database[] = [];
const NOW = Date.parse("2026-11-08T04:00:00Z");
afterEach(() => {
  for (const db of databases.splice(0)) db.close();
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

function fixture(browser: Browser, profile = "Default", home?: string) {
  home ??= mkdtempSync(join(tmpdir(), "ra-browser-test-"));
  if (!homes.includes(home)) homes.push(home);
  const file = join(home, browser.pathGlob.replace("*", profile));
  mkdirSync(dirname(file), { recursive: true });
  const db = new Database(file);
  databases.push(db);
  switch (browser.engine) {
    case "chromium":
      db.exec(`CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR);
        CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, transition INTEGER NOT NULL DEFAULT 0);`);
      break;
    case "firefox":
      db.exec(`CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR);
        CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER, visit_type INTEGER);`);
      break;
    case "safari":
      db.exec(`CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT NOT NULL);
        CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT);`);
  }
  function add(id: number, time: number, url = `https://example.org/${id}`, title: string | null = "合成页面") {
    switch (browser.engine) {
      case "chromium":
        db.run("INSERT INTO urls VALUES (?, ?, ?)", [id, url, title]);
        db.run("INSERT INTO visits VALUES (?, ?, ?, ?)", [id, id, (time - Date.UTC(1601, 0, 1)) * 1000, 7]);
        break;
      case "firefox":
        db.run("INSERT INTO moz_places VALUES (?, ?, ?)", [id, url, title]);
        db.run("INSERT INTO moz_historyvisits VALUES (?, ?, ?, ?)", [id, id, time * 1000, 2]);
        break;
      case "safari":
        db.run("INSERT INTO history_items VALUES (?, ?)", [id, url]);
        db.run("INSERT INTO history_visits VALUES (?, ?, ?, ?)", [id, id, (time - Date.UTC(2001, 0, 1)) / 1000, title]);
    }
  }
  return { home, file, db, add };
}

async function collect(home: string, browsers: readonly Browser[], state?: BrowserState, since?: Date, now = NOW + 120_000) {
  const records: RecordV1[] = [];
  const logs: string[] = [];
  const result = await collectBrowserHistory({
    home, browsers, device: "test-mac", state, since, now,
    onRecord: (record) => { expect(validateRecord(record)).toEqual({ ok: true }); records.push(record); },
    log: (message) => logs.push(message),
  });
  return { ...result, records, logs };
}

test("同站连续访问跨插件轮次合并，保留各地址与最后页标题", async () => {
  const chrome = BROWSERS[0]!;
  const f = fixture(chrome);
  const legacy: BrowserState = { version: 1, profiles: { "Chrome:Default": { lastId: 1, recent: [] } } };
  f.add(1, NOW - 21_000, "https://example.org/old", "已入库的旧页");
  f.add(2, NOW - 11_000, "https://example.org/new-1", "站内第一页");
  f.add(3, NOW - 4_000, "https://example.org/new-2", "站内第二页");
  const open = await collect(f.home, [chrome], legacy, undefined, NOW);
  expect(open.records).toEqual([]);
  expect(JSON.stringify(open.state)).not.toContain("example.org");

  f.add(4, NOW + 4_000, "https://example.org/new-3", "站内最后一页");
  f.add(5, NOW + 7_000, "https://example.net/final", "另一个站点");
  const closed = await collect(f.home, [chrome], open.state, undefined, NOW + 40_000);
  expect(closed.records.map(r => r.title)).toEqual(["站内最后一页", "另一个站点"]);
  expect(closed.records[0]).toMatchObject({
    source_ref: "Chrome:Default:2", kind: "span", context: { url: "https://example.org/new-3" },
  });
  expect(closed.records[0]?.body).toBe("站内最后一页\nhttps://example.org/new-1\nhttps://example.org/new-2\nhttps://example.org/new-3");
  const replay = await collect(f.home, [chrome], closed.state, new Date(NOW - 30_000), NOW + 40_000);
  expect(replay.records.map(r => r.source_ref)).toEqual(["Chrome:Default:1", "Chrome:Default:2", "Chrome:Default:5"]);
  expect((await collect(f.home, [chrome], closed.state, undefined, NOW + 50_000)).records).toEqual([]);
  const hub = new HubDB(join(f.home, "tacit-validation.sqlite"), "synthetic");
  try {
    expect(hub.ingest([replay.records[0]!, ...closed.records])).toMatchObject({ accepted: 3, rejected: [] });
    expect(hub.ingest(replay.records)).toMatchObject({ duplicates: 3, rejected: [] });
    for (const path of ["new-1", "new-2", "new-3"]) {
      const matches = hub.list(new URLSearchParams({ q: `https://example.org/${path}` })).records;
      expect(matches.map(record => record.id)).toEqual([closed.records[0]?.id]);
    }
    expect(hub.get(replay.records[0]!.id)?.body).toBe("已入库的旧页\nhttps://example.org/old");
  } finally { hub.close(); }
});

test("同页再次访问延后站内片段关闭，随后同站页面跨轮仍合并", async () => {
  const chrome = BROWSERS[0]!, f = fixture(chrome);
  const first = "https://example.org/start", last = "https://example.org/next";
  f.add(1, NOW - 35_000, first, "首访");
  f.add(2, NOW - 10_000, first, "再次访问");
  const open = await collect(f.home, [chrome], undefined, undefined, NOW);
  f.add(3, NOW + 10_000, last, "站内最后一页");

  const verify = async (state?: BrowserState) => {
    const closed = await collect(f.home, [chrome], state, undefined, NOW + 41_000);
    expect(closed.records).toHaveLength(1);
    const [record] = closed.records;
    expect(record).toMatchObject({ title: "站内最后一页", source_ref: "Chrome:Default:1", kind: "span",
      context: { url: last }, body: `站内最后一页\n${first}\n${last}` });
    expect(Date.parse(record!.t_start)).toBe(NOW - 35_000);
    expect(Date.parse(record!.t_end!)).toBe(NOW + 10_000);
  };
  await verify();
  expect(open.records).toEqual([]);
  await verify(open.state);
});

test("重导保留已入库的站内片段边界，迟到的页面仍能单独找到", async () => {
  const chrome = BROWSERS[0]!, f = fixture(chrome);
  f.add(1, NOW, "https://example.org/first", "已入库的第一页");
  const first = await collect(f.home, [chrome], undefined, undefined, NOW + 40_000);
  expect(first.records.map(r => r.source_ref)).toEqual(["Chrome:Default:1"]);
  f.add(2, NOW + 20_000, "https://example.org/late", "迟到的同站页面");
  const second = await collect(f.home, [chrome], first.state, undefined, NOW + 60_000);
  expect(second.records.map(r => r.source_ref)).toEqual(["Chrome:Default:2"]);

  const replay = await collect(f.home, [chrome], second.state, new Date(NOW), NOW + 60_000);
  const fields = ({ source_ref, t_start, t_end, title, body }: RecordV1) => ({ source_ref, t_start, t_end, title, body });
  expect(replay.records.map(fields)).toEqual([...first.records, ...second.records].map(fields));
});

test("迟到访问跨过待写片段的游标时，等到能完整提交再写入", async () => {
  const chrome = BROWSERS[0]!, f = fixture(chrome);
  f.add(1, NOW + 40_000, "https://other.example/active", "尚未结束的页面");
  f.add(2, NOW, "https://example.org/first", "迟到的第一页");
  const open = await collect(f.home, [chrome], undefined, undefined, NOW + 50_000);
  f.add(3, NOW + 20_000, "https://example.org/late", "迟到的第二页");
  const closed = await collect(f.home, [chrome], open.state, undefined, NOW + 75_000);

  expect(open.records).toEqual([]);
  expect(closed.records.map(r => r.source_ref)).toEqual(["Chrome:Default:2", "Chrome:Default:1"]);
  expect(closed.records[0]?.body).toBe("迟到的第二页\nhttps://example.org/first\nhttps://example.org/late");
  const replay = await collect(f.home, [chrome], closed.state, new Date(NOW), NOW + 80_000);
  expect(replay.records.map(r => r.source_ref)).toEqual(closed.records.map(r => r.source_ref));
});

test("重导对夹在新访问中的旧行保持原记录键，往返页面使用最后看到的标题", async () => {
  const chrome = BROWSERS[0]!;
  const f = fixture(chrome);
  const legacy: BrowserState = { version: 1, profiles: { "Chrome:Default": { lastId: 1, recent: [] } } };
  f.add(1, NOW - 20_000, "https://third.example/old", "浏览器已有的旧记录");
  f.add(2, NOW - 25_000, "https://site.example/step-one", "起始页");
  f.add(3, NOW - 15_000, "https://site.example/step-two", "中间页");
  f.add(4, NOW - 13_000, "https://site.example/step-one", "返回到的最后一页");
  const current = await collect(f.home, [chrome], legacy);
  const replay = await collect(f.home, [chrome], current.state, new Date(NOW - 31_000));
  expect(current.records.map(r => r.source_ref)).toEqual(["Chrome:Default:2"]);
  expect(replay.records.map(r => r.source_ref)).toEqual(["Chrome:Default:1", "Chrome:Default:2"]);
  expect(replay.records[1]).toMatchObject({
    title: "返回到的最后一页",
    body: "返回到的最后一页\nhttps://site.example/step-one\nhttps://site.example/step-two",
    context: { url: "https://site.example/step-one" },
  });
});

describe.each([BROWSERS[0]!, BROWSERS[3]!, BROWSERS[4]!])("$name 引擎", (browser) => {
  test("时间、默认七天、字段和显式回溯", async () => {
    const f = fixture(browser);
    f.add(1, NOW - 8 * 86400_000);
    f.add(2, NOW - 7 * 86400_000);
    f.add(3, NOW - 51_000, "https://name:password@example.org/path?token=synthetic%2f&x=1+2", "多行\n合成标题");
    f.add(4, NOW - 50_000, "https://example.net/empty", null);
    const first = await collect(f.home, [browser], undefined, undefined, NOW);
    expect(first.failed).toBe(false);
    expect(first.records.map((r) => Date.parse(r.t_start))).toEqual([NOW - 7 * 86400_000, NOW - 51_000, NOW - 50_000]);
    const record = first.records[1]!;
    const profile = browser.engine === "safari" ? "Safari" : "Default";
    expect(record.source_ref).toBe(`${browser.name}:${profile}:3`);
    expect(record.context).toEqual({
      app: browser.bundleId, url: "https://example.org/path?token=synthetic%2f&x=1+2",
      extra: { profile, ...(browser.engine === "safari" ? {} : { transition: browser.engine === "chromium" ? 7 : 2 }) },
    });
    expect(record.title).toBe("多行 合成标题");
    expect(record.body).toBe("多行 合成标题\nhttps://example.org/path?token=synthetic%2f&x=1+2");
    expect(record.kind).toBe("event");
    expect(record.source).toBe("mac.browser");
    expect(record.capture.method).toBe("db");
    expect(first.records[2]!.title).toBe("example.net");
    expect((await collect(f.home, [browser], undefined, new Date(NOW - 9 * 86400_000))).records).toHaveLength(4);
  });

  test("跳过内部页、本地地址和无效 URL，过滤项仍推进游标", async () => {
    const f = fixture(browser);
    const skip = ["chrome://settings", "about:blank", "file:///tmp/example", "data:text/plain,example",
      "chrome-extension://synthetic/page", "moz-extension://synthetic/page", "safari-web-extension://synthetic/page",
      "http://localhost:3000/path", "http://127.0.0.1/path", "http://127.2.3.4/", "http://[::1]/", "http://localhost./",
      "http://sub.localhost/", "not a URL"];
    skip.forEach((url, i) => f.add(i + 1, NOW - 1000, url));
    const result = await collect(f.home, [browser]);
    expect(result.records).toHaveLength(0);
    expect(Object.values(result.state.profiles)[0]!.lastId).toBe(skip.length);
    expect((await collect(f.home, [browser], result.state)).records).toHaveLength(0);
  });

  test("以第一次为基准去重，跨轮次保留，31 秒重新记录", async () => {
    const f = fixture(browser);
    const url = "https://example.org/repeat";
    f.add(1, NOW, url);
    f.add(2, NOW + 20_000, url);
    f.add(3, NOW + 30_000, url);
    const first = await collect(f.home, [browser]);
    expect(first.records).toHaveLength(1);
    expect(Object.values(first.state.profiles)[0]!.lastId).toBe(3);
    expect(JSON.stringify(first.state)).not.toContain(url);
    f.add(4, NOW + 25_000, url);
    const second = await collect(f.home, [browser], first.state);
    expect(second.records).toHaveLength(0);
    f.add(5, NOW + 31_000, url);
    f.add(6, NOW + 50_000, url);
    const third = await collect(f.home, [browser], second.state);
    expect(third.records.map((r) => r.source_ref?.split(":").at(-1))).toEqual(["5"]);
    expect((await collect(f.home, [browser], third.state)).records).toHaveLength(0);
    // 长时间未调用时，已有 profile 仍从主键继续，不受首次七天窗口限制。
    f.add(7, NOW - 20 * 86400_000, "https://example.org/backdated");
    expect((await collect(f.home, [browser], third.state)).records).toHaveLength(1);
    // 显式 --since（重新导入）从头扫描：已有 state 也能读到比游标旧的访问，重放结果与增量一致（hub 按 source_ref 去重），游标不倒退。
    const rescan = await collect(f.home, [browser], third.state, new Date(NOW));
    expect(rescan.records.map((r) => r.source_ref?.split(":").at(-1))).toEqual(["1", "5"]);
    expect(Object.values(rescan.state.profiles)[0]!.lastId).toBe(7);
    const all = await collect(f.home, [browser], third.state, new Date(NOW - 30 * 86400_000));
    expect(all.records.map((r) => r.source_ref?.split(":").at(-1))).toEqual(["7", "1", "5"]);
  });

  test("读取未 checkpoint 的 WAL，复制后源库不变", async () => {
    const f = fixture(browser);
    f.db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA wal_checkpoint(TRUNCATE)");
    f.add(1, NOW);
    expect(existsSync(f.file + "-wal")).toBe(true);
    const before = ["", "-wal", "-shm"].map((suffix) => readFileSync(f.file + suffix));
    expect((await collect(f.home, [browser])).records).toHaveLength(1);
    expect(["", "-wal", "-shm"].map((suffix) => readFileSync(f.file + suffix))).toEqual(before);
  });
});

test("所有 Chromium 路径均可发现，profile 独立推进及去重", async () => {
  const first = fixture(BROWSERS[0]!);
  first.add(1, NOW, "https://example.org/shared");
  fixture(BROWSERS[0]!, "Profile 2", first.home).add(1, NOW, "https://example.org/shared");
  fixture(BROWSERS[1]!, "Default", first.home).add(1, NOW, "https://example.org/shared");
  fixture(BROWSERS[2]!, "Default", first.home).add(1, NOW, "https://example.org/shared");
  const result = await collect(first.home, BROWSERS.slice(0, 3));
  expect(result.records).toHaveLength(4);
  expect(new Set(result.records.map((r) => r.source_ref)).size).toBe(4);
  expect(Object.keys(result.state.profiles)).toHaveLength(4);
  expect((await collect(first.home, BROWSERS.slice(0, 3), result.state)).records).toHaveLength(0);
});

test("临时副本在正常、回调异常、复制异常和损坏库路径均删除", () => {
  const f = fixture(BROWSERS[0]!);
  const tempDirs = () => readdirSync(tmpdir()).filter((name) => name.startsWith("ra-browser-")).sort();
  const before = tempDirs();
  let copied = "";
  withDatabaseCopy(f.file, (db) => { copied = db.filename; expect(existsSync(copied)).toBe(true); });
  expect(existsSync(dirname(copied))).toBe(false);
  expect(() => withDatabaseCopy(f.file, () => { throw new Error("合成异常"); })).toThrow("合成异常");
  expect(() => withDatabaseCopy(f.file + ".missing", () => {})).toThrow();
  const broken = join(f.home, "broken.db");
  writeFileSync(broken, "合成损坏数据库");
  expect(() => withDatabaseCopy(broken, (db) => db.query("SELECT * FROM visits").all())).toThrow();
  expect(tempDirs()).toEqual(before);
});

test("Safari 读取失败时给权限提示，其他浏览器仍正常工作", async () => {
  const f = fixture(BROWSERS[0]!);
  f.add(1, NOW);
  const result = await collect(f.home, [BROWSERS[4]!, BROWSERS[0]!]);
  expect(result.records).toHaveLength(1);
  expect(result.failed).toBe(false);
  expect(result.logs.join("\n")).toContain("完全磁盘访问");
});

test("其他浏览器损坏时保留原游标，继续处理其余浏览器", async () => {
  const f = fixture(BROWSERS[0]!);
  writeFileSync(f.file, "合成损坏数据库");
  fixture(BROWSERS[3]!, "test-profile", f.home).add(1, NOW);
  const result = await collect(f.home, [BROWSERS[0]!, BROWSERS[3]!]);
  expect(result.failed).toBe(true);
  expect(result.records).toHaveLength(1);
  expect(result.state.profiles["Chrome:Default"]).toBeUndefined();
});

test("URL 原始查询串不变，凭据含冒号、编码及 @ 时完全移除", () => {
  expect(cleanUrl("https://user:p%40ss:word@example.org/a?b=%2f&b=+1#fragment")?.url)
    .toBe("https://example.org/a?b=%2f&b=+1#fragment");
  expect(cleanUrl("https://u:p@ss@example.org/a")?.url).toBe("https://example.org/a");
  expect(cleanUrl("https://example.org/?email=a@b")?.url).toBe("https://example.org/?email=a@b");
});

async function cli(home: string, args: string[]) {
  const proc = Bun.spawn([process.execPath, join(import.meta.dir, "main.ts"), ...args], {
    env: { ...process.env, RA_BROWSER_HOME: home }, stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  return { stdout, stderr, code };
}

test("CLI 输出 JSONL 和末尾单个 checkpoint，state 只读，环境变量替换 home", async () => {
  const f = fixture(BROWSERS[0]!);
  f.add(1, Date.now() - 60_000);
  const first = await cli(f.home, ["--device", "test-mac"]);
  expect(first.code).toBe(0);
  const lines = first.stdout.trim().split("\n").map((line) => JSON.parse(line));
  expect(lines.map((line) => line.type)).toEqual(["record", "checkpoint"]);
  expect(validateRecord(lines[0].record)).toEqual({ ok: true });
  const stateFile = join(f.home, "state.json");
  const stateText = JSON.stringify(lines[1].state);
  writeFileSync(stateFile, stateText);
  const second = await cli(f.home, ["--device", "test-mac", "--state", stateFile]);
  expect(second.code).toBe(0);
  expect(second.stdout.trim().split("\n").map((line) => JSON.parse(line).type)).toEqual(["checkpoint"]);
  expect(readFileSync(stateFile, "utf8")).toBe(stateText);
  const filtered = await cli(f.home, ["--device", "test-mac", "--since", "2099-01-01T00:00:00Z"]);
  expect(filtered.code).toBe(0);
  expect(filtered.stdout).not.toContain('"type":"record"');
});

test("CLI 输入错误或损坏库非零退出且不输出 checkpoint", async () => {
  const f = fixture(BROWSERS[0]!);
  const stateFile = join(f.home, "state.json");
  writeFileSync(stateFile, '{"version":1,"profiles":{"Chrome:Default":{"lastId":"bad","recent":[]}}}');
  for (const args of [[], ["--device", "BAD"], ["--device", "mac", "--since", "bad"],
    ["--device", "mac", "--state"], ["--device", "mac", "--state", stateFile]]) {
    const result = await cli(f.home, args);
    expect(result.code).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr.length).toBeGreaterThan(0);
  }
  writeFileSync(f.file, "合成损坏数据库");
  const failed = await cli(f.home, ["--device", "test-mac"]);
  expect(failed.code).toBe(1);
  expect(failed.stdout).not.toContain('"type":"checkpoint"');
});
