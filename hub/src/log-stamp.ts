/** Local time with offset, the same shape distill and collector already write as `at`. */
export function localLogTime(now: number): string {
  const date = new Date(now), offset = -date.getTimezoneOffset();
  const hours = String(Math.floor(Math.abs(offset) / 60)).padStart(2, "0");
  const minutes = String(Math.abs(offset) % 60).padStart(2, "0");
  return new Date(now + offset * 60_000).toISOString().slice(0, 19) + (offset >= 0 ? "+" : "-") + hours + ":" + minutes;
}

/**
 * hub.log had no times, so repeated "Hub 已启动" lines could not be told apart from crashes (2026-11-23).
 * JSON object lines gain a leading `at` (the runtime page already reads it); plain text gets a time prefix,
 * which keeps substring checks such as /Hub 已启动：http:…/ working.
 */
export function stampLogLine(line: string, now: number): string {
  if (line.startsWith("{")) {
    try {
      const value = JSON.parse(line) as unknown;
      if (value && typeof value === "object" && !Array.isArray(value)) {
        return "at" in value ? line : JSON.stringify({ at: localLogTime(now), ...value });
      }
    } catch { /* not JSON: falls through to the text form */ }
  }
  return `${localLogTime(now)} ${line}`;
}

/** Long-running processes only: one-shot CLI commands keep their plain output. */
export function stampConsole(now: () => number = Date.now) {
  for (const level of ["log", "error", "warn"] as const) {
    const write = console[level].bind(console);
    console[level] = (...args: unknown[]) => {
      if (args.length === 1 && typeof args[0] === "string") write(stampLogLine(args[0], now()));
      else write(localLogTime(now()), ...args);
    };
  }
}
