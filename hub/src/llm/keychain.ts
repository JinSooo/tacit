// 模型提供方 API key 的钥匙串读写。和 readKey 同一位置：service record-anything、account provider:<名字>。
// 只经 /usr/bin/security（AGENTS.md）；key 不进命令行参数、日志、错误信息或文件。
import { spawn } from "node:child_process";
import type { KeyProvider } from "./config.ts";

export interface Keychain {
  has(provider: KeyProvider): Promise<boolean>;
  set(provider: KeyProvider, key: string): Promise<void>;
  /** 返回删除前是否存在。 */
  remove(provider: KeyProvider): Promise<boolean>;
}

const SECURITY = "/usr/bin/security";
const SERVICE = "record-anything";
/** security -i 按双引号解析一行命令，引号和反斜杠无法原样写入（2026-11-10 实测）；API key 本来也只用可见 ASCII。 */
export const KEY_PATTERN = /^[\x21\x23-\x5b\x5d-\x7e]{8,1024}$/;

function run(command: string, args: string[], input?: string): Promise<number | null> {
  return new Promise(resolve => {
    // 输出一律丢弃：-i 模式的提示和诊断不能流到中枢日志。
    const child = spawn(command, args, { stdio: ["pipe", "ignore", "ignore"] });
    const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
    child.on("error", () => { clearTimeout(timer); resolve(null); });
    child.on("close", code => { clearTimeout(timer); resolve(code); });
    child.stdin.on("error", () => { /* 进程提前退出时由 close 报告 */ });
    child.stdin.end(input ?? "");
  });
}

/** command 只在测试里换成假的 security，生产固定 /usr/bin/security。 */
export function securityKeychain(command = SECURITY): Keychain {
  const run_ = (args: string[], input?: string) => run(command, args, input);
  return {
  async has(provider) {
    // 不带 -w：只查条目属性，不读出密码，也不会触发钥匙串授权框。
    const code = await run_(["find-generic-password", "-s", SERVICE, "-a", `provider:${provider}`]);
    if (code === 0) return true;
    if (code === 44) return false;
    throw new Error("无法查询钥匙串");
  },
  async set(provider, key) {
    if (!KEY_PATTERN.test(key)) throw new Error("API key 格式无效");
    // 交互模式从 stdin 读命令，key 不出现在进程参数里（ps 看不到）；-U 覆盖已有条目。
    const code = await run_(["-i"], `add-generic-password -U -s ${SERVICE} -a provider:${provider} -w "${key}"\n`);
    if (code !== 0) throw new Error("写入钥匙串失败");
  },
  async remove(provider) {
    const code = await run_(["delete-generic-password", "-s", SERVICE, "-a", `provider:${provider}`]);
    if (code === 0) return true;
    if (code === 44) return false;
    throw new Error("删除钥匙串条目失败");
  },
  };
}
export const systemKeychain = securityKeychain();
