/** 中枢全部密钥（db-key、device-key、provider:<名称>、relay-space-<空间编号>，Mac 上还有 audio-key-hex）的统一存取。
 *  同步接口；失败一律抛 SecretError（固定类别）。 */
export interface SecretStore {
  readonly backend: "keychain" | "sealed-file";
  /** 条目不存在返回 null；读不出来抛错，调用方不得因此新建密钥。 */
  read(account: string): string | null;
  /** 只判断条目是否存在，不取出内容。 */
  has(account: string): boolean;
  /** 覆盖写入。 */
  write(account: string, value: string): void;
  /** 只在条目不存在时写入，返回是否由本次调用创建；已存在不改动。 */
  create(account: string, value: string): boolean;
  /** 返回删除前是否存在。 */
  remove(account: string): boolean;
}
