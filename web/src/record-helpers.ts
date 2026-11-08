// 共享包会读取磁盘上的 schema；浏览器只保留这两个不依赖 Node 的函数。
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export function ulid(timeMs = Date.now()): string {
  let time = Math.floor(timeMs);
  let prefix = "";
  for (let i = 0; i < 10; i++) { prefix = alphabet[time % 32] + prefix; time = Math.floor(time / 32); }
  return prefix + Array.from(crypto.getRandomValues(new Uint8Array(16)), value => alphabet[value % 32]).join("");
}
export function toLocalIso(value: Date | number): string {
  const date = typeof value === "number" ? new Date(value) : value;
  const offset = -date.getTimezoneOffset();
  const pad = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0");
  return `${new Date(date.getTime() + offset * 60000).toISOString().slice(0, 19)}${offset >= 0 ? "+" : "-"}${pad(offset / 60)}:${pad(offset % 60)}`;
}
