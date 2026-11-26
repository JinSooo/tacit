// Run with Bun. Stale translations warn by default and fail with --strict.
// Broken relative links and invalid source headers always fail.
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DOCS } from "../site/build";

const root = fileURLToPath(new URL("../", import.meta.url));
const strict = process.argv.includes("--strict");

const topLevelDirectories = readdirSync(root, { withFileTypes: true })
  .filter(entry => entry.isDirectory())
  .map(entry => entry.name);
const zhDirectory = join(root, "docs/zh");
const docNames = new Set(DOCS.map(({ slug }) => `${slug}.md`));
if (existsSync(zhDirectory)) {
  for (const entry of readdirSync(zhDirectory, { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith(".md")) docNames.add(entry.name);
  }
}

const docPairs = [
  { source: "README.md", translation: "README.zh-CN.md" },
  ...Array.from(docNames, name => ({
    source: `docs/${name}`,
    translation: `docs/zh/${name}`,
  })),
  ...topLevelDirectories.map(dir => ({
    source: `${dir}/README.md`,
    translation: `${dir}/README.zh-CN.md`,
  })).filter(({ source, translation }) =>
    existsSync(join(root, source)) || existsSync(join(root, translation)),
  ),
];

function relativeTargets(markdown: string): Set<string> {
  const targets = new Set<string>();

  // Rendering handles Markdown reference links and excludes links in code.
  const html = Bun.markdown.html(markdown, { tables: true });
  new HTMLRewriter()
    .on("a[href]", { element: tag => { targets.add(tag.getAttribute("href")!); } })
    .on("img[src]", { element: tag => { targets.add(tag.getAttribute("src")!); } })
    .on("img[srcset], source[srcset]", {
      element(tag) {
        // README uses <picture> sources for dark-mode images.
        const srcset = tag.getAttribute("srcset")!;
        for (const candidate of srcset.split(/,\s+/)) {
          targets.add(candidate.trim().split(/\s+/, 1)[0]);
        }
      },
    })
    .transform(html);

  return targets;
}

const attributeEntities: Record<string, string> = {
  amp: "&", quot: '"', apos: "'", lt: "<", gt: ">",
};

function linkExists(doc: string, target: string): boolean {
  try {
    const url = target.replace(/&(amp|quot|apos|lt|gt|#\d+|#x[\da-fA-F]+);/g, (_, entity: string) => {
      if (entity.startsWith("#x")) return String.fromCodePoint(Number.parseInt(entity.slice(2), 16));
      if (entity.startsWith("#")) return String.fromCodePoint(Number(entity.slice(1)));
      return attributeEntities[entity];
    });
    if (/^(?:[a-z][a-z\d+.-]*:|\/)/i.test(url)) return true;
    const path = url.split(/[?#]/, 1)[0];
    if (!path) return true;
    return existsSync(resolve(root, dirname(doc), decodeURIComponent(path)));
  } catch {
    return false;
  }
}

let staleCount = 0;
let sourceErrors = 0;
let brokenLinks = 0;

const legacyPaths = ["docs/en", ...topLevelDirectories.map(dir => `${dir}/README.en.md`)];
for (const path of legacyPaths) {
  if (existsSync(join(root, path))) {
    console.error(`Legacy documentation path: ${path}`);
    sourceErrors++;
  }
}

function readDocument(doc: string): string | undefined {
  try {
    return readFileSync(join(root, doc), "utf8");
  } catch {
    console.error(`Cannot read documentation file: ${doc}`);
    sourceErrors++;
    return undefined;
  }
}

function checkLinks(doc: string, markdown: string): void {
  for (const target of relativeTargets(markdown)) {
    if (!linkExists(doc, target)) {
      console.error(`Broken relative link in ${doc}: ${target}`);
      brokenLinks++;
    }
  }
}

for (const { source, translation } of docPairs) {
  const english = readDocument(source);
  const chinese = readDocument(translation);

  if (english !== undefined) {
    if (/^\s*<!--\s*source\s*:/i.test(english)) {
      console.error(`English source must omit the source header: ${source}`);
      sourceErrors++;
    }
    checkLinks(source, english);
  }
  if (chinese === undefined) continue;

  checkLinks(translation, chinese);
  const header = /^<!-- source: (.+) @ ([a-f0-9]{40}|[a-f0-9]{64}) -->\r?(?:\n|$)/.exec(chinese);
  if (!header || header[1] !== source) {
    console.error(`Invalid or missing source header in ${translation}. Expected ${source} and its Git blob hash.`);
    sourceErrors++;
    continue;
  }
  if (english === undefined) continue;

  const recorded = header[2];
  const current = execFileSync("git", ["hash-object", "--", source], {
    cwd: root,
    encoding: "utf8",
  }).trim();
  if (current !== recorded) {
    console.warn(`Stale translation: ${translation} (source ${source} changed from ${recorded} to ${current}).`);
    staleCount++;
  }
}

console.log(
  `Checked ${docPairs.length} English docs and ${docPairs.length} Chinese translations: ` +
  `${staleCount} stale, ${sourceErrors} source errors, ${brokenLinks} broken relative links.`,
);
if (sourceErrors || brokenLinks || (strict && staleCount)) process.exitCode = 1;
