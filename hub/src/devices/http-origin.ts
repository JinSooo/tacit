/** Accept a single HTTP(S) authority, optionally followed by the root slash. */
export function httpOrigin(value: unknown): string | null {
  if (typeof value !== "string" || !/^https?:\/\/[^/?#@\\\s\x00-\x1f\x7f]+\/?$/i.test(value)) return null;
  const url = URL.parse(value);
  return url && url.port !== "0" ? url.origin : null;
}
