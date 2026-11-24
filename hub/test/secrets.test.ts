import { checkAccount } from "../src/secrets/accounts.ts";
import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig } from "../src/config.ts";
import { exportSealedFileGuide, deviceKeychain, relayKeychain } from "../src/keys.ts";
import { SecretError, defaultSecretStore, keychainStore, openSecretStore, secretBackendOf, sealedFileStore, type SecurityRun } from "../src/secrets/index.ts";

// 全部使用虚构数据和临时目录，不触碰真实钥匙串，也不读写 ~/Library。
const ROOT = "ab".repeat(32), OTHER_ROOT = "cd".repeat(32);
const DB_KEY = "12".repeat(32), DEVICE_KEY = "34".repeat(32);
const SPACE = "A".repeat(22), RELAY_TOKEN = "t".repeat(43), PROVIDER_KEY = "sk-synthetic-0123456789";

let base: string, data: string, keyDir: string, keyFile: string;
beforeEach(() => {
  base = mkdtempSync(join(tmpdir(), "ra-secrets-"));
  data = join(base, "data"); keyDir = join(base, "keys"); keyFile = join(keyDir, "master.key");
  mkdirSync(data, { recursive: true, mode: 0o700 }); mkdirSync(keyDir, { recursive: true });
  writeFileSync(keyFile, ROOT + "\n", { mode: 0o400 });
});
afterEach(() => rmSync(base, { recursive: true, force: true }));

const open = (o: object = {}) => sealedFileStore({ dataDir: data, masterKeyFile: keyFile, ...o });
const reason = (fn: () => unknown) => { try { fn(); } catch (e) { return e instanceof SecretError ? e.reason : `非 SecretError：${String(e)}`; } return "未抛错"; };

// ---------------- sealed-file ----------------

test("sealed-file：读、写、覆盖、create、删除", () => {
  const s = open();
  expect(s.backend).toBe("sealed-file");
  expect(s.read("db-key")).toBeNull();
  expect(s.has("db-key")).toBe(false);
  expect(existsSync(join(data, "secrets.enc"))).toBe(false); // 只读不会创建文件
  s.write("db-key", DB_KEY);
  s.write("provider:anthropic", PROVIDER_KEY);
  s.write(`relay-space-${SPACE}`, RELAY_TOKEN);
  expect(s.read("db-key")).toBe(DB_KEY);
  expect(s.has("provider:anthropic")).toBe(true);
  s.write("db-key", "56".repeat(32));
  expect(s.read("db-key")).toBe("56".repeat(32));
  expect(s.create("device-key", DEVICE_KEY)).toBe(true);
  expect(s.create("device-key", "78".repeat(32))).toBe(false); // 已存在不改
  expect(s.read("device-key")).toBe(DEVICE_KEY);
  expect(s.remove("provider:anthropic")).toBe(true);
  expect(s.remove("provider:anthropic")).toBe(false);
  expect(s.read("provider:anthropic")).toBeNull();
  expect(s.read(`relay-space-${SPACE}`)).toBe(RELAY_TOKEN);
});

test("sealed-file：文件内容是密文，权限 0600，没有残留临时文件和锁", () => {
  const s = open();
  s.write("db-key", DB_KEY);
  s.write("provider:openai-compatible", PROVIDER_KEY);
  const file = join(data, "secrets.enc");
  const raw = readFileSync(file);
  for (const needle of [DB_KEY, PROVIDER_KEY, "db-key", "provider", ROOT]) expect(raw.toString("latin1")).not.toContain(needle);
  expect(Bun.file(file).size).toBeGreaterThan(30);
  expect(Bun.spawnSync(["stat", "-f", "%Lp", file]).stdout.toString().trim()).toBe("600");
  expect(readdirSync(data).sort()).toEqual(["secrets.enc"]);
  // 每次写入用新随机数：同样内容再写一遍，密文不同。
  s.write("db-key", DB_KEY);
  expect(readFileSync(file).equals(raw)).toBe(false);
});

test("sealed-file：另一个进程重启后能读到，也能看到别的进程写入的新值", () => {
  open().write("db-key", DB_KEY);
  const script = `
    import { sealedFileStore } from ${JSON.stringify(join(import.meta.dir, "../src/secrets/index.ts"))};
    const s = sealedFileStore({ dataDir: ${JSON.stringify(data)}, masterKeyFile: ${JSON.stringify(keyFile)} });
    process.stdout.write(String(s.read("db-key")));
    s.write("provider:anthropic", ${JSON.stringify(PROVIDER_KEY)});`;
  const child = Bun.spawnSync([process.execPath, "-e", script], { env: { PATH: process.env.PATH ?? "" } });
  expect(child.exitCode).toBe(0);
  expect(child.stdout.toString()).toBe(DB_KEY);
  expect(open().read("provider:anthropic")).toBe(PROVIDER_KEY);
});

test("sealed-file：写入中途失败时旧文件完整、不留临时文件；并发写入由锁串行化", () => {
  const s = open();
  s.write("db-key", DB_KEY);
  const file = join(data, "secrets.enc"), before = readFileSync(file);
  const failing = open({ beforeCommit: () => { throw new Error("模拟断电"); } });
  expect(reason(() => failing.write("provider:anthropic", PROVIDER_KEY))).toBe("secrets_write");
  expect(readFileSync(file).equals(before)).toBe(true);
  expect(readdirSync(data).sort()).toEqual(["secrets.enc"]);
  expect(s.read("provider:anthropic")).toBeNull();

  // 别的进程持有锁：超时报 secrets_locked，不写；锁过期（崩溃遗留）则清掉继续。
  const lock = `${file}.lock`;
  writeFileSync(lock, "");
  expect(reason(() => open({ lockTimeoutMs: 100 }).write("db-key", "99".repeat(32)))).toBe("secrets_locked");
  expect(readFileSync(file).equals(before)).toBe(true);
  const old = new Date(Date.now() - 120_000);
  utimesSync(lock, old, old);
  s.write("db-key", "99".repeat(32));
  expect(s.read("db-key")).toBe("99".repeat(32));
  expect(existsSync(lock)).toBe(false);
});

test("sealed-file：根密钥放在数据目录内（含符号链接绕过）被拒", () => {
  const inside = join(data, "master.key");
  writeFileSync(inside, ROOT, { mode: 0o400 });
  expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: inside }))).toBe("master_key_in_data_dir");
  // 数据目录里放一个指向目录外根密钥的链接，同样拒绝（链接本身就在数据目录里）。
  const link = join(data, "link.key");
  symlinkSync(keyFile, link);
  expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: link }))).toBe("master_key_in_data_dir");
  // 目录外的链接指向数据目录内的文件，同样拒绝。
  const outside = join(keyDir, "outside-link.key");
  symlinkSync(inside, outside);
  expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: outside }))).toBe("master_key_in_data_dir");
  // 数据目录路径带 .. 的写法也不能绕过。
  expect(reason(() => sealedFileStore({ dataDir: join(data, "..", "data"), masterKeyFile: inside }))).toBe("master_key_in_data_dir");
  expect(readdirSync(data).sort()).toEqual(["link.key", "master.key"]); // 没有新建任何密钥文件
});

test("sealed-file：根密钥权限过宽、不是文件、相对路径、格式不对都被拒", () => {
  for (const mode of [0o644, 0o640, 0o604, 0o660]) {
    chmodSync(keyFile, mode);
    expect(reason(() => open())).toBe("master_key_permissions");
  }
  chmodSync(keyFile, 0o600);
  expect(open().backend).toBe("sealed-file");
  chmodSync(keyFile, 0o400);
  expect(open().backend).toBe("sealed-file");
  expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: keyDir }))).toBe("master_key_unreadable");
  expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: "keys/master.key" }))).toBe("master_key_path");
  for (const bad of ["abc", "zz".repeat(32), ROOT + ROOT]) {
    const f = join(keyDir, "bad.key");
    rmSync(f, { force: true }); writeFileSync(f, bad, { mode: 0o400 });
    expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: f }))).toBe("master_key_format");
  }
  // 原始 32 字节也接受。
  const raw = join(keyDir, "raw.key");
  writeFileSync(raw, Buffer.from(ROOT, "hex"), { mode: 0o400 });
  const a = sealedFileStore({ dataDir: data, masterKeyFile: raw });
  a.write("db-key", DB_KEY);
  expect(open().read("db-key")).toBe(DB_KEY); // 与十六进制写法是同一把密钥
});

test("sealed-file：缺根密钥或根密钥不对时失败，不新建任何文件或密钥", () => {
  open().write("db-key", DB_KEY);
  const file = join(data, "secrets.enc"), before = readFileSync(file);
  const files = readdirSync(data).sort();
  // 根密钥文件不存在 / 没提供。
  expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: join(keyDir, "gone.key") }))).toBe("master_key_unreadable");
  expect(reason(() => sealedFileStore({ dataDir: data }))).toBe("master_key_missing");
  // 错的根密钥：AEAD 解不开，直接失败。
  const wrong = join(keyDir, "wrong.key");
  writeFileSync(wrong, OTHER_ROOT, { mode: 0o400 });
  expect(reason(() => sealedFileStore({ dataDir: data, masterKeyFile: wrong }))).toBe("secrets_undecryptable");
  // 文件被截断 / 篡改。
  for (const mutate of [(b: Buffer) => b.subarray(0, b.length - 1), (b: Buffer) => { const c = Buffer.from(b); c[c.length - 20] ^= 1; return c; }, () => Buffer.from("garbage")]) {
    writeFileSync(file, mutate(before));
    expect(["secrets_undecryptable", "secrets_corrupt"]).toContain(reason(() => open()));
  }
  writeFileSync(file, before);
  expect(open().read("db-key")).toBe(DB_KEY);
  expect(readdirSync(data).sort()).toEqual(files);
  expect(readFileSync(file).equals(before)).toBe(true);
});

test("sealed-file：错误只带固定类别，不含密钥、账号名或路径", () => {
  const wrong = join(keyDir, "wrong.key");
  open().write("db-key", DB_KEY);
  writeFileSync(wrong, OTHER_ROOT, { mode: 0o400 });
  for (const fn of [
    () => sealedFileStore({ dataDir: data, masterKeyFile: wrong }),
    () => open().write("db-key", "bad value"),
    () => open().read("provider:../../etc"),
    () => sealedFileStore({ dataDir: data, masterKeyFile: join(data, "x") }),
  ]) {
    try { fn(); throw new Error("应当失败"); } catch (e) {
      const message = String((e as Error).message) + JSON.stringify(e);
      expect(e).toBeInstanceOf(SecretError);
      for (const leak of [ROOT, OTHER_ROOT, DB_KEY, base, "provider:../../etc", "bad value"]) expect(message).not.toContain(leak);
    }
  }
});

test("账号白名单与值格式：未知账号、路径穿越、audio-key-hex 在 sealed-file 下都被拒", () => {
  const s = open();
  for (const account of ["", "db-key ", "DB-KEY", "token", "provider:", "provider:Bad", "provider:../x", "relay-space-short", `relay-space-${"A".repeat(23)}`, "audio-key-hex2", "secrets.enc", "__proto__"]) {
    expect(reason(() => s.read(account))).toBe("invalid_account");
    expect(reason(() => s.write(account, DB_KEY))).toBe("invalid_account");
    expect(reason(() => s.remove(account))).toBe("invalid_account");
  }
  expect(reason(() => s.read("audio-key-hex"))).toBe("backend_unsupported");
  expect(reason(() => s.write("audio-key-hex", DB_KEY))).toBe("backend_unsupported");
  // 值格式按账号检查。
  expect(reason(() => s.write("db-key", "NOT-HEX"))).toBe("invalid_value");
  expect(reason(() => s.write("device-key", "ab".repeat(16)))).toBe("invalid_value");
  expect(reason(() => s.write("provider:anthropic", 'has"quote-0123'))).toBe("invalid_value");
  expect(reason(() => s.write(`relay-space-${SPACE}`, "short"))).toBe("invalid_value");
  expect(existsSync(join(data, "secrets.enc"))).toBe(false);
});

// ---------------- keychain（注入假 security） ----------------

function fakeSecurity() {
  const items = new Map<string, string>(), calls: { args: string[]; input?: string }[] = [];
  const run: SecurityRun = (args, input) => {
    calls.push({ args, input });
    const account = args[args.indexOf("-a") + 1] ?? "";
    if (args[0] === "find-generic-password") {
      const v = items.get(account);
      return v === undefined ? { status: 44, stdout: "" } : { status: 0, stdout: args.includes("-w") ? v + "\n" : "" };
    }
    if (args[0] === "-i") {
      const m = /^add-generic-password (-U )?-s record-anything -a (\S+) -w "([^"]*)"\n$/.exec(input ?? "");
      if (!m) return { status: 1, stdout: "" };
      if (!m[1] && items.has(m[2]!)) return { status: 0, stdout: "" }; // -i 的退出码不可靠：重复条目也返回 0
      items.set(m[2]!, m[3]!);
      return { status: 0, stdout: "" };
    }
    if (args[0] === "delete-generic-password") return items.delete(account) ? { status: 0, stdout: "" } : { status: 44, stdout: "" };
    return { status: 1, stdout: "" };
  };
  return { items, calls, run };
}

test("keychain 后端：条目名与命令和现有行为一致，密钥只经标准输入", () => {
  const { items, calls, run } = fakeSecurity();
  const s = keychainStore(run);
  expect(s.backend).toBe("keychain");
  expect(s.read("db-key")).toBeNull();
  s.write("db-key", DB_KEY);
  s.write("audio-key-hex", "ef".repeat(32)); // Mac 模式才有
  s.write("provider:anthropic", PROVIDER_KEY);
  s.write(`relay-space-${SPACE}`, RELAY_TOKEN);
  expect([...items.keys()].sort()).toEqual(["audio-key-hex", "db-key", "provider:anthropic", `relay-space-${SPACE}`]);
  expect(s.read("db-key")).toBe(DB_KEY);
  expect(s.has("provider:anthropic")).toBe(true);
  expect(s.remove("provider:anthropic")).toBe(true);
  expect(s.remove("provider:anthropic")).toBe(false);
  const writes = calls.filter(c => c.args[0] === "-i");
  expect(writes[0]!.input).toBe(`add-generic-password -U -s record-anything -a db-key -w "${DB_KEY}"\n`);
  expect(calls.find(c => c.args[0] === "find-generic-password" && c.args.includes("-w"))!.args).toEqual(["find-generic-password", "-s", "record-anything", "-a", "db-key", "-w"]);
  // has 不读出密码。
  expect(calls.filter(c => c.args.includes("provider:anthropic") && c.args[0] === "find-generic-password").some(c => !c.args.includes("-w"))).toBe(true);
  for (const secret of [DB_KEY, PROVIDER_KEY, RELAY_TOKEN, "ef".repeat(32)]) for (const c of calls) expect(c.args.join(" ")).not.toContain(secret);
});

test("keychain 后端：create 不覆盖已有条目；失败只给固定类别；白名单同样生效", () => {
  const { items, run } = fakeSecurity();
  const s = keychainStore(run);
  expect(s.create("device-key", DEVICE_KEY)).toBe(true);
  expect(s.create("device-key", "78".repeat(32))).toBe(false);
  expect(items.get("device-key")).toBe(DEVICE_KEY);
  expect(reason(() => s.read("nope"))).toBe("invalid_account");
  expect(reason(() => s.write("db-key", 'a"b'))).toBe("invalid_value");
  expect(reason(() => keychainStore(() => ({ status: 36, stdout: "" })).read("db-key"))).toBe("keychain_read");
  expect(reason(() => keychainStore(() => ({ status: null, stdout: "", error: new Error("ETIMEDOUT") })).read("db-key"))).toBe("keychain_read");
  expect(reason(() => keychainStore(() => ({ status: 0, stdout: "\n" })).read("db-key"))).toBe("keychain_read");
  expect(reason(() => keychainStore(() => ({ status: 1, stdout: "" })).write("db-key", DB_KEY))).toBe("keychain_write");
  expect(reason(() => keychainStore(() => ({ status: 1, stdout: "" })).remove("db-key"))).toBe("keychain_delete");
});

test("远端 Agent 的钥匙串账户只接受规范的后台 ID，本机账户仍可读写", () => {
  const { calls, run } = fakeSecurity();
  const keychain = keychainStore(run);
  for (const base of ["agent-device-key", "agent-context-cache-key"]) {
    const hubID = "a".repeat(25) + "4";
    for (const account of [base, base + "." + hubID]) {
      expect(keychain.create(account, DEVICE_KEY)).toBe(true);
      expect(keychain.read(account)).toBe(DEVICE_KEY);
      expect(reason(() => checkAccount(account, "sealed-file"))).toBe("backend_unsupported");
    }
    const before = calls.length;
    for (const suffix of ["", "a".repeat(25), "a".repeat(27), "a".repeat(25) + "b", hubID + "\n", "../" + hubID, hubID.toUpperCase()]) {
      expect(reason(() => keychain.read(base + "." + suffix))).toBe("invalid_account");
    }
    expect(calls).toHaveLength(before);
  }
});

// ---------------- 后端选择与 loadConfig ----------------

test("后端选择：Mac 默认 keychain，其他系统默认 sealed-file，可显式指定，写错报错", () => {
  expect(secretBackendOf({}, "darwin")).toBe("keychain");
  expect(secretBackendOf({}, "linux")).toBe("sealed-file");
  expect(secretBackendOf({ RA_SECRET_BACKEND: "sealed-file" }, "darwin")).toBe("sealed-file");
  expect(secretBackendOf({ RA_SECRET_BACKEND: "keychain" }, "linux")).toBe("keychain");
  expect(() => secretBackendOf({ RA_SECRET_BACKEND: "env" }, "darwin")).toThrow(SecretError);
  const env = { RA_SECRET_BACKEND: "sealed-file", RA_DATA_DIR: data, RA_MASTER_KEY_FILE: keyFile };
  expect(openSecretStore({ env }).backend).toBe("sealed-file");
  expect(defaultSecretStore(env)).toBe(defaultSecretStore(env));
});

test("RA_MASTER_KEY 只给开发测试：能用，并且告警", () => {
  const warnings: string[] = [];
  const s = openSecretStore({ env: { RA_SECRET_BACKEND: "sealed-file", RA_DATA_DIR: data, RA_MASTER_KEY: ROOT }, sealed: { warn: m => warnings.push(m) } });
  s.write("db-key", DB_KEY);
  expect(open().read("db-key")).toBe(DB_KEY);
  expect(warnings).toHaveLength(1);
  expect(warnings[0]).not.toContain(ROOT);
});

test("loadConfig（sealed-file）：新库生成并保存数据库密钥，重启后同一把", () => {
  const env = { RA_SECRET_BACKEND: "sealed-file", RA_DATA_DIR: data, RA_MASTER_KEY_FILE: keyFile, RA_PORT: "0" };
  const first = loadConfig(env);
  expect(first.dbKey).toMatch(/^[0-9a-f]{64}$/);
  expect(existsSync(join(data, "secrets.enc"))).toBe(true);
  expect(loadConfig(env).dbKey).toBe(first.dbKey);
  expect(open().read("db-key")).toBe(first.dbKey);
});

test("loadConfig（sealed-file）：已有数据库时缺根密钥、缺 secrets.enc、根密钥不对都失败，且不新建密钥", () => {
  const env = { RA_SECRET_BACKEND: "sealed-file", RA_DATA_DIR: data, RA_MASTER_KEY_FILE: keyFile, RA_PORT: "0" };
  loadConfig(env);
  writeFileSync(join(data, "history.db"), "synthetic encrypted database");
  const secrets = join(data, "secrets.enc"), before = readFileSync(secrets);
  const snapshot = () => readdirSync(data).sort();
  const files = snapshot();

  // 根密钥文件被拿走。
  rmSync(keyFile);
  expect(() => loadConfig(env)).toThrow(expect.objectContaining({ code: "master_key_unreadable" }));
  // 根密钥换成别的：解不开 secrets.enc。
  writeFileSync(keyFile, OTHER_ROOT, { mode: 0o400 });
  expect(() => loadConfig(env)).toThrow(expect.objectContaining({ code: "master_key_unreadable", reason: "secrets_undecryptable" }));
  expect(readFileSync(secrets).equals(before)).toBe(true);
  // 完全没提供根密钥。
  expect(() => loadConfig({ ...env, RA_MASTER_KEY_FILE: undefined })).toThrow(expect.objectContaining({ code: "master_key_unreadable", reason: "master_key_missing" }));
  expect(snapshot()).toEqual(files);

  // secrets.enc 丢了（根密钥是对的）：数据库在，不得新建 db-key。
  writeFileSync(keyFile + ".tmp", ROOT, { mode: 0o400 });
  rmSync(keyFile); symlinkSync(keyFile + ".tmp", keyFile);
  rmSync(secrets);
  expect(() => loadConfig(env)).toThrow(expect.objectContaining({ code: "db_key_missing" }));
  expect(existsSync(secrets)).toBe(false);
});

test("loadConfig（sealed-file）：根密钥在数据目录内时拒绝启动，不创建 secrets.enc", () => {
  const inside = join(data, "master.key");
  writeFileSync(inside, ROOT, { mode: 0o400 });
  expect(() => loadConfig({ RA_SECRET_BACKEND: "sealed-file", RA_DATA_DIR: data, RA_MASTER_KEY_FILE: inside, RA_PORT: "0" })).toThrow(expect.objectContaining({ code: "master_key_unreadable", reason: "master_key_in_data_dir" }));
  expect(existsSync(join(data, "secrets.enc"))).toBe(false);
});

// ---------------- 设备密钥、信箱令牌、keys export ----------------

test("设备密钥和信箱令牌经默认存储读写（sealed-file）：保持原有语义", () => {
  const saved = { ...process.env };
  Object.assign(process.env, { RA_SECRET_BACKEND: "sealed-file", RA_DATA_DIR: data, RA_MASTER_KEY_FILE: keyFile });
  try {
    expect(deviceKeychain.read()).toBeNull();
    deviceKeychain.write(DEVICE_KEY);
    expect(deviceKeychain.read()).toBe(DEVICE_KEY);
    expect(() => deviceKeychain.write("56".repeat(32))).toThrow("无法保存设备密钥"); // 不覆盖已有身份
    expect(() => deviceKeychain.write("bad")).toThrow("设备密钥格式无效");
    expect(relayKeychain.read(SPACE)).toBeNull();
    relayKeychain.write(SPACE, RELAY_TOKEN);
    expect(relayKeychain.read(SPACE)).toBe(RELAY_TOKEN);
    relayKeychain.remove(SPACE);
    relayKeychain.remove(SPACE);
    expect(relayKeychain.read(SPACE)).toBeNull();
    expect(() => relayKeychain.read("short")).toThrow("信箱空间编号无效");
    expect(() => relayKeychain.write(SPACE, "short")).toThrow("信箱密钥格式无效");
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  }
});

test("keys export（sealed-file）：只给备份指引，不打印任何密钥；缺数据库密钥时标记缺失", () => {
  const env = { RA_SECRET_BACKEND: "sealed-file", RA_DATA_DIR: data, RA_MASTER_KEY_FILE: keyFile };
  const store = open();
  const empty = exportSealedFileGuide(env, new Date("2026-11-23T00:00:00Z"), store);
  expect(empty.missing).toEqual(["数据库"]);
  store.write("db-key", DB_KEY);
  store.write("device-key", DEVICE_KEY);
  const guide = exportSealedFileGuide(env, new Date("2026-11-23T00:00:00Z"), store);
  expect(guide.missing).toEqual([]);
  expect(guide.text).toContain("分开备份");
  expect(guide.text).toContain("丢了无法恢复");
  expect(guide.text).toContain(keyFile);
  for (const secret of [ROOT, DB_KEY, DEVICE_KEY]) expect(guide.text).not.toContain(secret);
  expect(guide.text).not.toContain("add-generic-password");
});

test("serve 在 sealed-file 缺根密钥时启动失败，写入既有的“密钥读不出来”诊断并且不建密钥", () => {
  const env = { PATH: process.env.PATH ?? "", HOME: base, RA_DATA_DIR: data, RA_SECRET_BACKEND: "sealed-file", RA_MASTER_KEY_FILE: join(keyDir, "gone.key"), RA_PORT: "0" };
  const child = Bun.spawnSync([process.execPath, join(import.meta.dir, "../src/cli.ts"), "serve"], { env });
  expect(child.exitCode).toBe(1);
  expect(readFileSync(join(data, "hub-startup-error.json"), "utf8")).toContain("db_key_unreadable");
  expect(existsSync(join(data, "secrets.enc"))).toBe(false);
  expect(child.stdout.toString() + child.stderr.toString()).not.toContain(keyDir);
});
