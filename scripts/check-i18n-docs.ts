// Run with Bun. Stale translations warn by default and fail with --strict.
// Broken relative links and invalid source headers always fail.
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const strict = process.argv.includes("--strict");

const englishDocs = [
  "README.md",
  ...readdirSync(join(root, "docs/en"), { withFileTypes: true })
    .filter(entry => entry.isFile() && entry.name.endsWith(".md"))
    .map(entry => `docs/en/${entry.name}`),
  ...readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => `${entry.name}/README.en.md`)
    .filter(file => existsSync(join(root, file))),
].sort();

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

for (const doc of [...englishDocs, "README.zh-CN.md"]) {
  const markdown = readFileSync(join(root, doc), "utf8");

  if (doc !== "README.zh-CN.md") {
    const header = /^<!-- source: (.+) @ ([a-f0-9]{40}|[a-f0-9]{64}) -->\r?(?:\n|$)/.exec(markdown);
    if (!header) {
      console.error(`Invalid or missing source header in ${doc}.`);
      sourceErrors++;
    } else {
      const [, source, recorded] = header;
      const sourcePath = relative(root, resolve(root, source));
      try {
        if (!sourcePath || isAbsolute(source) || sourcePath === ".." || sourcePath.startsWith(`..${sep}`)) {
          throw new Error("Expected a repository-relative source path");
        }
        const current = execFileSync("git", ["hash-object", "--", sourcePath], {
          cwd: root,
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        }).trim();
        if (current !== recorded) {
          console.warn(`Stale translation: ${doc} (source ${source} changed from ${recorded} to ${current}).`);
          staleCount++;
        }
      } catch {
        console.error(`Cannot hash source ${source} for ${doc}. Use an existing repository-relative file.`);
        sourceErrors++;
      }
    }
  }

  for (const target of relativeTargets(markdown)) {
    if (!linkExists(doc, target)) {
      console.error(`Broken relative link in ${doc}: ${target}`);
      brokenLinks++;
    }
  }
}

console.log(
  `Checked ${englishDocs.length} English docs and ${englishDocs.length + 1} link sets: ` +
  `${staleCount} stale, ${sourceErrors} source errors, ${brokenLinks} broken relative links.`,
);
if (sourceErrors || brokenLinks || (strict && staleCount)) process.exitCode = 1;
