import { spawnSync } from "node:child_process";

/** 备份数据库、音频和已创建的中枢设备身份。 */
export const DEVICE_KEY_ACCOUNT = "device-key";
export const KEY_ACCOUNTS = [
  { account: "db-key", label: "数据库" },
  { account: "audio-key-hex", label: "音频" },
  { account: DEVICE_KEY_ACCOUNT, label: "设备" },
] as const;

export type ReadKey = (account: string) => { status: number | null; value: string };

export const readKeychain: ReadKey = account => {
  const r = spawnSync("/usr/bin/security", ["find-generic-password", "-s", "record-anything", "-a", account, "-w"], { encoding: "utf8", timeout: 10_000, stdio: ["ignore", "pipe", "ignore"] });
  return { status: r.status, value: (r.stdout ?? "").trim() };
};

/** 输出可直接执行的恢复命令；只在用户明确运行 `keys export` 时打印到终端，不写文件。 */
export function exportKeys(read: ReadKey = readKeychain, today = new Date()): { text: string; missing: string[] } {
  const lines = [
    `# Tacit 密钥备份（${today.toLocaleDateString("sv-SE")}）`,
    "# 存进密码管理器，不要存成普通文件，也不要发给别人。",
    "# 恢复：先把数据目录拷回 ~/Library/Application Support/record-anything/，",
    "# 再在终端运行下面几行，最后安装并打开 Tacit。顺序不能反，否则会生成新密钥。",
  ];
  const missing: string[] = [];
  for (const { account, label } of KEY_ACCOUNTS) {
    const { status, value } = read(account);
    if (account === DEVICE_KEY_ACCOUNT && status === 44) continue;
    // 密钥是十六进制；其他内容不拼进命令，避免引号注入。
    if (status === 0 && (account === DEVICE_KEY_ACCOUNT ? /^[0-9a-f]{64}$/i : /^[0-9a-f]{32,128}$/i).test(value)) lines.push(`security add-generic-password -U -s record-anything -a ${account} -w '${value}'`);
    else { missing.push(label); lines.push(`# ${label}密钥（${account}）：钥匙串里没有或读取失败${status === 44 ? "（还没生成）" : ""}`); }
  }
  return { text: lines.join("\n"), missing };
}

export interface DeviceKeyStorage {
  read(): string | null;
  write(value: string): void;
}

export const deviceKeychain: DeviceKeyStorage = {
  read() {
    const { status, value } = readKeychain(DEVICE_KEY_ACCOUNT);
    if (status === 44) return null;
    if (status !== 0) throw new Error("无法读取设备密钥");
    return value;
  },
  write(value) {
    if (!/^[0-9a-f]{64}$/.test(value)) throw new Error("设备密钥格式无效");
    // 经 stdin 传入，避免私钥出现在进程参数中。
    const result = spawnSync("/usr/bin/security", ["-i"], {
      input: `add-generic-password -s record-anything -a ${DEVICE_KEY_ACCOUNT} -w "${value}"\n`,
      timeout: 10_000, stdio: ["pipe", "ignore", "ignore"],
    });
    if (result.status !== 0 || deviceKeychain.read() !== value) throw new Error("无法保存设备密钥");
  },
};
