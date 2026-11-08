import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
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

async function collect(home: string, browsers: readonly Browser[], state?: BrowserState, since?: Date) {
  const records: RecordV1[] = [];
  const logs: string[] = [];
  const result = await collectBrowserHistory({
    home, browsers, device: "test-mac", state, since, now: NOW,
    onRecord: (record) => { expect(validateRecord(record)).toEqual({ ok: true }); records.push(record); },
    log: (message) => logs.push(message),
  });
  return { ...result, records, logs };
}

describe.each([BROWSERS[0]!, BROWSERS[3]!, BROWSERS[4]!])("$name 引擎", (browser) => {
  test("时间、默认七天、字段和显式回溯", async () => {
    const f = fixture(browser);
    f.add(1, NOW - 8 * 86400_000);
    f.add(2, NOW - 7 * 86400_000);
    f.add(3, NOW - 2000, "https://name:password@example.org/path?token=synthetic%2f&x=1+2", "多行\n合成标题");
    f.add(4, NOW - 1000, "https://example.net/empty", null);
    const first = await collect(f.home, [browser]);
    expect(first.failed).toBe(false);
    expect(first.records.map((r) => Date.parse(r.t_start))).toEqual([NOW - 7 * 86400_000, NOW - 2000, NOW - 1000]);
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
    expect((await collect(f.home, [browser], third.state, new Date(NOW))).records).toHaveLength(0);
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
  f.add(1, Date.now());
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
