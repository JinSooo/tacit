import { spawnSync } from "node:child_process";

/** 钥匙串里的全部密钥：数据库（hub）和音频（采集端、转写进程）。丢了任何一个，对应的数据就打不开。 */
export const KEY_ACCOUNTS = [
  { account: "db-key", label: "数据库" },
  { account: "audio-key-hex", label: "音频" },
] as const;

export type ReadKey = (account: string) => { status: number | null; value: string };

const readKeychain: ReadKey = account => {
  const r = spawnSync("security", ["find-generic-password", "-s", "record-anything", "-a", account, "-w"], { encoding: "utf8", timeout: 10_000 });
  return { status: r.status, value: (r.stdout ?? "").trim() };
};

/** 输出可直接执行的恢复命令；只在用户明确运行 `keys export` 时打印到终端，不写文件。 */
export function exportKeys(read: ReadKey = readKeychain, today = new Date()): { text: string; missing: string[] } {
  const lines = [
    `# record-anything 密钥备份（${today.toLocaleDateString("sv-SE")}）`,
    "# 存进密码管理器，不要存成普通文件，也不要发给别人。",
    "# 恢复：先把数据目录拷回 ~/Library/Application Support/record-anything/，",
    "# 再在终端运行下面几行，最后运行 ./install.sh。顺序不能反，否则安装会生成新密钥。",
  ];
  const missing: string[] = [];
  for (const { account, label } of KEY_ACCOUNTS) {
    const { status, value } = read(account);
    // 两个密钥都是十六进制；其他内容不拼进命令，避免引号注入。
    if (status === 0 && /^[0-9a-f]{32,128}$/i.test(value)) lines.push(`security add-generic-password -U -s record-anything -a ${account} -w '${value}'`);
    else { missing.push(label); lines.push(`# ${label}密钥（${account}）：钥匙串里没有或读取失败${status === 44 ? "（还没生成）" : ""}`); }
  }
  return { text: lines.join("\n"), missing };
}
