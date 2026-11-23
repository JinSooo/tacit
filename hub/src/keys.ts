import { SecretError, SECRETS_FILE, defaultSecretStore, openSecretStore, relayAccount as relaySecretAccount, runSystemSecurity, secretBackendOf, type SecretStore } from "./secrets/index.ts";

/** 备份数据库、音频和已创建的中枢设备身份。 */
export const DEVICE_KEY_ACCOUNT = "device-key";
export const KEY_ACCOUNTS = [
  { account: "db-key", label: "数据库" },
  { account: "audio-key-hex", label: "音频" },
  { account: DEVICE_KEY_ACCOUNT, label: "设备" },
] as const;

export type ReadKey = (account: string) => { status: number | null; value: string };

export const readKeychain: ReadKey = account => {
  const r = runSystemSecurity(["find-generic-password", "-s", "record-anything", "-a", account, "-w"]);
  return { status: r.status, value: r.stdout.trim() };
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

/** 把存储层的固定类别错误换成原有的面向调用方的消息，code / reason 保留给启动诊断。 */
function fail(message: string, error: unknown): never {
  const e = error instanceof SecretError ? error : null;
  throw Object.assign(new Error(message), e ? { code: e.code, reason: e.reason } : {});
}
// 惰性取默认后端：keychain（Mac 默认）或 sealed-file（RA_SECRET_BACKEND / 非 Mac），见 secrets/index.ts。
const store = (): SecretStore => defaultSecretStore();

// 名字沿用 keychain 时代，实际按当前后端存取；Mac 默认后端下与此前行为一致。
export const deviceKeychain: DeviceKeyStorage = {
  read() {
    try { return store().read(DEVICE_KEY_ACCOUNT); } catch (error) { return fail("无法读取设备密钥", error); }
  },
  write(value) {
    if (!/^[0-9a-f]{64}$/.test(value)) throw new Error("设备密钥格式无效");
    // 只在不存在时创建：已有设备密钥不能被覆盖，否则全部已配对设备失效。
    let created = false;
    try { created = store().create(DEVICE_KEY_ACCOUNT, value); } catch (error) { return fail("无法保存设备密钥", error); }
    if (!created) throw new Error("无法保存设备密钥");
  },
};

export interface RelayKeyStorage {
  read(space: string): string | null;
  write(space: string, value: string): void;
  remove(space: string): void;
}

function relayAccount(space: string) {
  if (!/^[A-Za-z0-9_-]{22}$/.test(space)) throw new Error("信箱空间编号无效");
  return relaySecretAccount(space);
}

export const relayKeychain: RelayKeyStorage = {
  read(space) {
    const account = relayAccount(space);
    try { return store().read(account); } catch (error) { return fail("无法读取信箱密钥", error); }
  },
  write(space, value) {
    const account = relayAccount(space);
    if (!/^[A-Za-z0-9_-]{43}$/.test(value)) throw new Error("信箱密钥格式无效");
    try { store().write(account, value); } catch (error) { fail("无法保存信箱密钥", error); }
  },
  remove(space) {
    const account = relayAccount(space);
    try { store().remove(account); } catch (error) { fail("无法删除信箱密钥", error); }
  },
};

/** sealed-file 模式下的 `keys export`：不打印任何密钥，只给备份指引并核对哪些条目已存在。 */
export function exportSealedFileGuide(env: NodeJS.ProcessEnv = process.env, today = new Date(), store: SecretStore = openSecretStore({ env })): { text: string; missing: string[] } {
  const missing = store.has("db-key") ? [] : ["数据库"];
  const keyFile = env.RA_MASTER_KEY_FILE?.trim();
  const lines = [
    `# Tacit 密钥备份指引（${today.toLocaleDateString("sv-SE")}，服务端 sealed-file 模式）`,
    "# 这个模式下所有密钥都用一把 32 字节根密钥加密，存在数据目录里的 " + SECRETS_FILE + "。不会打印任何密钥内容。",
    `# 根密钥来源：${keyFile ? `文件 ${keyFile}（RA_MASTER_KEY_FILE）` : "环境变量 RA_MASTER_KEY（只限开发测试，请改用 RA_MASTER_KEY_FILE）"}。`,
    "# 必须分开备份两样东西，并存放在不同的地方：",
    "#   1. 根密钥文件：存进密码管理器或离线保存，不要放进数据目录、不要和数据库备份存在一起；丢了无法恢复，也无法重新生成。",
    `#   2. 数据目录（history.db、${SECRETS_FILE} 等）：按常规备份。只有它没有根密钥，解不开。`,
    "# 恢复：把数据目录放回原处，把根密钥文件放到数据目录之外并设为 0400，把 RA_MASTER_KEY_FILE 指向它，再启动中枢。",
    "# 根密钥缺失或不对时中枢会直接拒绝启动，不会新建密钥。",
    `# 数据库密钥（db-key）：${store.has("db-key") ? `已在 ${SECRETS_FILE} 里` : `${SECRETS_FILE} 里没有（还没生成）`}。`,
    `# 设备密钥（device-key）：${store.has("device-key") ? `已在 ${SECRETS_FILE} 里` : "还没生成"}。`,
  ];
  return { text: lines.join("\n"), missing };
}

/** 按当前后端导出：keychain 给恢复命令，sealed-file 给备份指引。 */
export function exportKeysForBackend(env: NodeJS.ProcessEnv = process.env): { text: string; missing: string[] } {
  return secretBackendOf(env) === "keychain" ? exportKeys() : exportSealedFileGuide(env);
}
