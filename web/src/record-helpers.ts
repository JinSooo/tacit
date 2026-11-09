// 共享包会读取磁盘上的 schema；浏览器只保留这两个不依赖 Node 的函数。
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
// 同一毫秒内按生成顺序递增，和中枢 packages/record 的 ulid 一致。
// 按时间记住最近一次的随机部分：显式传入的旧时间和当前时间交替生成时也能各自递增。
const recent = new Map<number, number[]>();
export function ulid(timeMs = Date.now()): string {
  const time = Math.floor(timeMs);
  let rand: number[];
  const last = recent.get(time);
  if (last) {
    rand = [...last];
    let i = rand.length - 1;
    while (i >= 0 && rand[i] === 31) rand[i--] = 0;
    if (i < 0) throw new Error("同一毫秒内的 ULID 用尽");
    rand[i]!++;
  } else {
    rand = Array.from(crypto.getRandomValues(new Uint8Array(16)), value => value % 32);
    rand[0] = rand[0]! % 16;
  }
  recent.delete(time); recent.set(time, rand);
  if (recent.size > 256) recent.delete(recent.keys().next().value!);
  let t = time, prefix = "";
  for (let i = 0; i < 10; i++) { prefix = alphabet[t % 32] + prefix; t = Math.floor(t / 32); }
  return prefix + rand.map(n => alphabet[n]).join("");
}
export function toLocalIso(value: Date | number): string {
  const date = typeof value === "number" ? new Date(value) : value;
  const offset = -date.getTimezoneOffset();
  const pad = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0");
  return `${new Date(date.getTime() + offset * 60000).toISOString().slice(0, 19)}${offset >= 0 ? "+" : "-"}${pad(offset / 60)}:${pad(offset % 60)}`;
}
