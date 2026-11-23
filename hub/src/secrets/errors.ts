// 密钥存放层的错误：消息和 reason 都是固定类别，不含密钥、账号名、路径或系统返回的原文。
// code 沿用启动诊断里已有的类别（AGENTS.md「故障与排障」）：根密钥与 secrets.enc 的问题一律 master_key_unreadable。
export type SecretReason =
  | "invalid_account" | "invalid_value" | "invalid_config" | "backend_unsupported"
  | "keychain_unavailable" | "keychain_read" | "keychain_write" | "keychain_delete"
  | "master_key_missing" | "master_key_path" | "master_key_in_data_dir" | "master_key_permissions" | "master_key_format" | "master_key_unreadable"
  | "secrets_undecryptable" | "secrets_corrupt" | "secrets_write" | "secrets_locked";

export type SecretCode = "master_key_unreadable" | "secret_unreadable" | "secret_write_failed" | "secret_invalid";

const TABLE: Record<SecretReason, [SecretCode, string]> = {
  invalid_account: ["secret_invalid", "密钥账号名不在允许范围内"],
  invalid_value: ["secret_invalid", "密钥内容格式无效"],
  invalid_config: ["secret_invalid", "密钥后端配置无效"],
  backend_unsupported: ["secret_invalid", "当前密钥后端不支持这个账号"],
  keychain_unavailable: ["secret_unreadable", "钥匙串在这个系统上不可用"],
  keychain_read: ["secret_unreadable", "无法读取钥匙串"],
  keychain_write: ["secret_write_failed", "无法写入钥匙串"],
  keychain_delete: ["secret_write_failed", "无法删除钥匙串条目"],
  master_key_missing: ["master_key_unreadable", "没有提供根密钥"],
  master_key_path: ["master_key_unreadable", "根密钥路径必须是绝对路径"],
  master_key_in_data_dir: ["master_key_unreadable", "根密钥文件不能放在数据目录内"],
  master_key_permissions: ["master_key_unreadable", "根密钥文件权限过宽，只允许所有者读写（0400 或 0600）"],
  master_key_format: ["master_key_unreadable", "根密钥必须是 32 字节（64 位十六进制或 32 字节原始内容）"],
  master_key_unreadable: ["master_key_unreadable", "无法读取根密钥文件"],
  secrets_undecryptable: ["master_key_unreadable", "secrets.enc 无法用当前根密钥解开"],
  secrets_corrupt: ["master_key_unreadable", "secrets.enc 内容损坏"],
  secrets_write: ["secret_write_failed", "无法写入 secrets.enc"],
  secrets_locked: ["secret_write_failed", "secrets.enc 正被其他进程占用"],
};

export class SecretError extends Error {
  readonly code: SecretCode;
  constructor(readonly reason: SecretReason) {
    const [code, message] = TABLE[reason];
    super(message);
    this.name = "SecretError";
    this.code = code;
  }
}
