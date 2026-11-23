// macOS 钥匙串后端：只经 /usr/bin/security（AGENTS.md「安装与运维」：自签名应用每次重建都算新程序）。
// 写入走 `security -i` 从标准输入读命令，密钥不出现在进程参数里；输出一律丢弃，不进日志。
import { spawnSync } from "node:child_process";
import { SecretError } from "./errors.ts";
import { checkAccount, checkValue } from "./accounts.ts";
import type { SecretStore } from "./store.ts";

export const KEYCHAIN_SERVICE = "record-anything";
const SECURITY = "/usr/bin/security";

/** 执行一次 security；status 为 null 表示没跑起来或超时。测试里换成假的执行器，生产固定用系统自带的。 */
export type SecurityRun = (args: string[], input?: string) => { status: number | null; stdout: string; error?: unknown };

export const runSystemSecurity: SecurityRun = (args, input) => {
  if (process.platform !== "darwin") return { status: null, stdout: "", error: new Error("unsupported") };
  const r = spawnSync(SECURITY, args, {
    encoding: "utf8", input, timeout: 10_000, killSignal: "SIGKILL",
    stdio: [input === undefined ? "ignore" : "pipe", "pipe", "ignore"],
  });
  return { status: r.status, stdout: r.stdout ?? "", error: r.error };
};

export function keychainStore(run: SecurityRun = runSystemSecurity): SecretStore {
  const find = (account: string, withPassword: boolean) =>
    run(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, ...(withPassword ? ["-w"] : [])]);
  const read = (account: string): string | null => {
    checkAccount(account, "keychain");
    const r = find(account, true);
    if (r.error || r.status === null) throw new SecretError(run === runSystemSecurity && process.platform !== "darwin" ? "keychain_unavailable" : "keychain_read");
    if (r.status === 44) return null;
    const value = r.stdout.trim();
    if (r.status !== 0 || !value) throw new SecretError("keychain_read");
    return value;
  };
  const add = (account: string, value: string, overwrite: boolean) => {
    checkAccount(account, "keychain");
    checkValue(account, value);
    // 值已按账号规则限定为不含引号、反斜杠、空白的字符，拼进一行命令不会被截断或注入。
    const r = run(["-i"], `add-generic-password ${overwrite ? "-U " : ""}-s ${KEYCHAIN_SERVICE} -a ${account} -w "${value}"\n`);
    // -i 模式的退出码不可靠（重复条目也可能返回 0），以读回为准。
    if (r.error) return false;
    try { return read(account) === value; } catch { return false; }
  };
  return {
    backend: "keychain",
    read,
    has(account) {
      checkAccount(account, "keychain");
      // 不带 -w：只查条目属性，不读出密码，也不会触发钥匙串授权框。
      const r = find(account, false);
      if (r.status === 0 && !r.error) return true;
      if (r.status === 44) return false;
      throw new SecretError("keychain_read");
    },
    write(account, value) { if (!add(account, value, true)) throw new SecretError("keychain_write"); },
    create(account, value) {
      if (read(account) !== null) return false;
      return add(account, value, false);
    },
    remove(account) {
      checkAccount(account, "keychain");
      const r = run(["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account]);
      if (!r.error && r.status === 0) return true;
      if (!r.error && r.status === 44) return false;
      throw new SecretError("keychain_delete");
    },
  };
}

/** 短命钩子可以取消钥匙串读取。秘密只走子进程管道。 */
export async function readKeychainAsync(account: string, signal: AbortSignal): Promise<string | null> {
  checkAccount(account, "keychain");
  const { status, stdout } = await runSecurityAsync(
    ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"], signal,
  );
  if (status === 44) return null;
  if (status !== 0 || !stdout.trim()) throw new SecretError("keychain_read");
  return stdout.trim();
}

export async function createKeychainAsync(account: string, value: string, signal: AbortSignal): Promise<void> {
  checkAccount(account, "keychain");
  checkValue(account, value);
  // 不覆盖并发进程先生成的密钥，调用方写后重读。
  await runSecurityAsync(["-i"], signal, `add-generic-password -s ${KEYCHAIN_SERVICE} -a ${account} -w "${value}"\n`);
}

async function runSecurityAsync(args: string[], signal: AbortSignal, input?: string) {
  signal.throwIfAborted();
  const child = Bun.spawn([SECURITY, ...args], { stdin: input === undefined ? "ignore" : Buffer.from(input), stdout: "pipe", stderr: "ignore" });
  const cancel = () => { child.kill("SIGKILL"); };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    const [status, stdout] = await Promise.all([child.exited, new Response(child.stdout).text()]);
    signal.throwIfAborted();
    return { status, stdout };
  } finally { signal.removeEventListener("abort", cancel); }
}
