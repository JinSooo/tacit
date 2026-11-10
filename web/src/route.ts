// 当前页写在 location.hash 里（#/now），刷新能恢复，浏览器前进后退可用。
export const pages = ["history", "now", "pending", "audit", "status", "settings"] as const;
export type Page = typeof pages[number];

/**
 * 解析地址栏片段。除了 #/now 这类页面路径，还认两种旧写法：
 * cli open 打开的 #token=…，以及 Mac 客户端打开状态页用的 #token=…&status（也可以只写 #status）。
 */
export function parseHash(hash: string): { page: Page | null; token: string | null } {
  const raw = hash.replace(/^#/, "");
  const path = /^\/([\w-]*)/.exec(raw);
  if (path) return { page: (pages as readonly string[]).includes(path[1]!) ? path[1] as Page : null, token: null };
  const params = new URLSearchParams(raw);
  return { page: params.has("status") ? "status" : null, token: params.get("token") };
}

export function pageHash(page: Page): string {
  return `#/${page}`;
}

/** 地址栏没写页面时：带 ?thread= / ?project= 的旧链接打开读取记录，其余回到 History。 */
export function initialPage(hash: string, search: string): Page {
  return parseHash(hash).page ?? (/[?&](thread|project)=/.test(search) ? "audit" : "history");
}
