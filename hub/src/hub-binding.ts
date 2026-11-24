import { createHash } from "node:crypto";
import { closeSync, constants, fstatSync, lstatSync, openSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { base32, base64url, object } from "./devices/envelope.ts";

export interface RemoteHubBinding {
  hub_id: string;
  hub_pk: string;
  dir: string;
}

const maxBindingBytes = 64 * 1024;

function readBindingFile(file: string): string | null {
  // 与 Mac 端一致：数据目录本身是符号链接时拒绝（Mac 用 O_DIRECTORY|O_NOFOLLOW 打开目录）。
  const dir = lstatSync(dirname(file), { throwIfNoEntry: false });
  if (!dir) return null;
  if (!dir.isDirectory()) throw new Error("后台绑定目录不安全");
  let fd: number;
  try { fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw new Error("无法读取后台绑定");
  }
  try {
    const stat = fstatSync(fd);
    // Mac 是唯一写方，固定 0600；符号链接、非普通文件、他人可写或过大一律当损坏，不回退本机。
    if (!stat.isFile() || (stat.mode & 0o077) !== 0 || stat.size > maxBindingBytes) throw new Error("后台绑定文件不安全");
    return readFileSync(fd, "utf8");
  } finally { closeSync(fd); }
}

/**
 * 文件不存在才算本机模式（旧安装）。文件存在就必须是合法的 v1 绑定，否则抛错（fail closed）：
 * 远端已生效时，损坏的绑定绝不能让本机后台、封存库或本机 Agent 身份重新启用。
 * 合法组合与 Mac 端 HubBinding.validate 一致：local+local（无 remote）、remote+preparing、
 * remote+committed/switching_back（generation > 0）。preparing 仍走本机。
 */
export function readHubBinding(dataDir: string): { generation: number; remote: RemoteHubBinding | null } {
  const text = readBindingFile(join(dataDir, "hub-binding.json"));
  if (text === null) return { generation: 0, remote: null };
  const invalid = () => new Error("后台绑定格式无效");
  let row: Record<string, unknown> | null;
  try { row = object(JSON.parse(text)); } catch { throw invalid(); }
  const generation = row?.generation;
  if (!row || row.version !== 1 || typeof generation !== "number" || !Number.isSafeInteger(generation) || generation < 0) throw invalid();
  if (row.target === "local") {
    if (row.phase !== "local" || (row.remote !== null && row.remote !== undefined)) throw invalid();
    return { generation, remote: null };
  }
  if (row.target !== "remote" || !["preparing", "committed", "switching_back"].includes(row.phase as string)) throw invalid();
  const remote = object(row.remote);
  const key = base64url(remote?.hub_pk, 32);
  const id = key && base32(createHash("sha256").update(key).digest().subarray(0, 16));
  if (!remote || !id || remote.hub_id !== id || remote.dir !== `remote-${id}`) throw invalid();
  if (row.phase === "preparing") return { generation, remote: null };
  if (generation === 0) throw invalid();
  return { generation, remote: { hub_id: id, hub_pk: remote.hub_pk as string, dir: remote.dir } };
}
