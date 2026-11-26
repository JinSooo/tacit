export type Lang = "zh" | "en";

/** Stored settings and environment overrides accept only resolved languages. */
export function parseLang(input?: string | null): Lang | null {
  return input === "zh" || input === "en" ? input : null;
}

/** Resolve the highest-priority language tag, preserving header order for ties. */
export function resolveLang(acceptLanguage?: string | null, fallback: Lang = "en"): Lang {
  let preferred = fallback;
  let bestQuality = 0;
  for (const entry of acceptLanguage?.split(",") ?? []) {
    const [tag, weight, ...extra] = entry.split(";").map(part => part.trim());
    if (!tag || extra.length || !/^(?:[a-z]{1,8}(?:-[a-z0-9]{1,8})*|\*)$/i.test(tag)) continue;
    const quality = weight === undefined ? 1 : /^q=(0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/i.exec(weight)?.[1];
    if (quality === undefined || Number(quality) <= bestQuality) continue;
    bestQuality = Number(quality);
    preferred = tag === "*" ? fallback : /^zh(?:-|$)/i.test(tag) ? "zh" : "en";
  }
  return preferred;
}
