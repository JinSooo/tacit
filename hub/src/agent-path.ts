import { join } from "node:path";

export const SYSTEM_BIN_DIRS = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];

export function agentBinDirectories(home: string): string[] {
  return [".local/share/mise/shims", ".local/bin", ".bun/bin", ".npm-global/bin"].map(path => join(home, path))
    .concat(SYSTEM_BIN_DIRS);
}
