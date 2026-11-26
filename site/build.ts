// 官网构建：生成根路径语言分流页、中英文首页、独立下载页与 Markdown 文档站，并校验路由与链接一致性。
// 用法：bun site/build.ts          构建到 site/dist
//       bun site/build.ts --serve  构建并在 http://localhost:4300 预览（PORT 可覆盖），每次请求 HTML 时重新构建
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type Locale = "en" | "zh";
export type DocSlug = "trial-guide" | "troubleshooting" | "server-deployment" | "installation" | "plugins";

export interface DocMeta {
  slug: DocSlug;
  navTitle: Record<Locale, string>;
  summary: Record<Locale, string>;
}

export interface TocItem {
  level: 2 | 3;
  id: string;
  text: string;
}

export interface RenderedDoc {
  title: string;
  html: string;
  toc: TocItem[];
}

export interface BuildResult {
  pages: string[];
  homeSections: number;
  homeIds: number;
  downloadIds: number;
  downloadLinks: number;
  docCount: number;
  checkedLinks: number;
}

export const SITE_ORIGIN = "https://tacit.jinso.top";
export const REPO_BLOB_BASE = "https://github.com/JinSooo/tacit/blob/main";

export const DOCS: readonly DocMeta[] = [
  {
    slug: "trial-guide",
    navTitle: { en: "Getting started", zh: "快速上手" },
    summary: {
      en: "A 5-minute walkthrough covering installation, macOS permissions, summary models, and connecting your AI tools.",
      zh: "装之前花 5 分钟了解 Tacit 做什么、怎么安装、首次授权与连接 Claude Code、Codex。",
    },
  },
  {
    slug: "troubleshooting",
    navTitle: { en: "Troubleshooting", zh: "常见问题排查" },
    summary: {
      en: "What to check when Tacit won’t open, a source stops recording, sync stalls, or AI tools cannot connect.",
      zh: "应用打不开、后台起不来、来源缺失、同步异常与导出诊断信息的排查办法。",
    },
  },
  {
    slug: "server-deployment",
    navTitle: { en: "Server deployment", zh: "服务端部署" },
    summary: {
      en: "Run the encrypted background service on an always-on Linux server or Windows PC with Docker.",
      zh: "使用 Docker 在 Linux 服务器或 Windows 电脑上独立部署 24 小时在线的后台服务。",
    },
  },
  {
    slug: "installation",
    navTitle: { en: "Installation & releases", zh: "安装与发布" },
    summary: {
      en: "Inside the Mac app bundle, background runtime layout, signing, automatic updates, and release builds.",
      zh: "安装包结构、自签名与首次放行、更新机制、卸载方式与发版构建流程。",
    },
  },
  {
    slug: "plugins",
    navTitle: { en: "Source plugins", zh: "数据源插件说明" },
    summary: {
      en: "Manifest format, runtime contract, permissions preview, and packaging specification for custom sources.",
      zh: "扩展数据源的清单格式、运行协议、权限预览与更新卸载规格说明。",
    },
  },
] as const;

const DOC_SLUG_SET = new Set<string>(DOCS.map((doc) => doc.slug));

const root = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(root, "..");
const src = join(root, "src");
const dist = join(root, "dist");

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function decodeHtmlEntities(value: string): string {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&#x27;", "'")
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, hex: string) => String.fromCodePoint(parseInt(hex, 16)));
}

function expand(file: string, seen: string[] = []): string {
  if (seen.includes(file)) throw new Error(`循环引用：${[...seen, file].join(" → ")}`);
  const text = readFileSync(file, "utf8");
  return text.replace(/<!--\s*include:\s*([^\s]+)\s*-->/g, (_, rel: string) =>
    expand(resolve(dirname(file), rel), [...seen, file]),
  );
}

// 内联公共样式、脚本和来源符号，资源路径按页面深度前缀调整。
// 来源符号的 id 加 src- 前缀，避免和页面区块 id（如 #ai）重名。
// 脚本改成普通脚本并各自包一层块作用域，避免各脚本顶层变量重名。
function inline(html: string, assetPrefix: string): string {
  const read = (rel: string) => readFileSync(join(src, rel), "utf8");
  const sprite = read("assets/sources.svg")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace("<svg ", '<svg aria-hidden="true" width="0" height="0" style="position:absolute" ')
    .replace(/<symbol id="/g, '<symbol id="src-');
  return html
    .replace(/<link rel="stylesheet" href="([^"]+)">/g, (_, rel: string) => `<style>\n${read(rel)}</style>`)
    .replace(/<script type="module" src="([^"]+)"><\/script>/g, (_, rel: string) => `<script>{\n${read(rel)}}</script>`)
    .replaceAll("assets/sources.svg#", "#src-")
    .replace(/\b(href|src|srcset)="assets\//g, `$1="${assetPrefix}assets/`)
    .replace(/<body([^>]*)>/, (m) => `${m}\n${sprite}`);
}

/**
 * 兼容新旧两种 docs/ 目录布局：
 * - 旧布局（中文在 docs/<slug>.md，英文在 docs/en/<slug>.md）
 * - 新布局（英文在 docs/<slug>.md，中文在 docs/zh/<slug>.md）
 */
export function resolveDocSource(baseRepoRoot: string, locale: Locale, slug: DocSlug): string {
  const enSub = `docs/en/${slug}.md`;
  const zhSub = `docs/zh/${slug}.md`;
  const rootDoc = `docs/${slug}.md`;

  if (locale === "en") {
    if (existsSync(join(baseRepoRoot, enSub))) return enSub;
    if (existsSync(join(baseRepoRoot, zhSub)) && existsSync(join(baseRepoRoot, rootDoc))) return rootDoc;
    throw new Error(`找不到英文文档源：${enSub}（且未检测到英文优先布局 ${zhSub} + ${rootDoc}）`);
  }

  if (existsSync(join(baseRepoRoot, zhSub))) return zhSub;
  if (existsSync(join(baseRepoRoot, rootDoc))) return rootDoc;
  throw new Error(`找不到中文文档源：${zhSub} 或 ${rootDoc}`);
}

/**
 * 清洗文档顶部的 `<!-- source: ... -->` 注释以及 GitHub 专用的语言切换首行。
 */
export function stripDocPreamble(markdown: string): string {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  let index = 0;

  while (index < lines.length) {
    const trimmed = lines[index]!.trim();
    if (!trimmed) {
      index += 1;
      continue;
    }
    if (/^<!--\s*source:[\s\S]*?-->$/.test(trimmed)) {
      index += 1;
      continue;
    }
    // 匹配 GitHub 顶部语言切换行，例如：
    // [English](en/trial-guide.md)
    // English | [简体中文](../trial-guide.md)
    // [简体中文](zh/trial-guide.md) | English
    const strippedSegments = trimmed
      .split("|")
      .map((part) => part.trim())
      .filter(Boolean);
    const isLangLine =
      strippedSegments.length > 0 &&
      strippedSegments.every((seg) =>
        /^(?:English|简体中文|中文|\[(?:English|简体中文|中文)\]\([^)]+\))$/.test(seg),
      );
    if (isLangLine) {
      index += 1;
      continue;
    }
    break;
  }

  return lines.slice(index).join("\n");
}

/**
 * GitHub 风格标题锚点：保留 Unicode 字母数字、空格转连字符、去除标点。
 */
export function slugifyHeading(rawText: string): string {
  const plain = decodeHtmlEntities(rawText.replace(/<[^>]+>/g, ""))
    .trim()
    .toLowerCase();
  return plain
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

/**
 * 重写文档内链接：
 * - 同批用户文档的相对 .md 链接 -> 站内文档路由（如 ../troubleshooting/）
 * - 仓库内其他相对路径 -> GitHub blob/main 链接
 * - 外部 URL 与页内 #anchor 保持原样
 */
export function rewriteDocHref(href: string, sourceRepoRelPath: string, docSlugs: ReadonlySet<string> = DOC_SLUG_SET): string {
  if (!href || /^(?:https?:|mailto:|tel:|#)/i.test(href)) return href;

  const hashIndex = href.indexOf("#");
  const rawPath = hashIndex >= 0 ? href.slice(0, hashIndex) : href;
  const hash = hashIndex >= 0 ? href.slice(hashIndex) : "";
  if (!rawPath) return href;

  const baseDir = posix.dirname(sourceRepoRelPath.replaceAll("\\", "/"));
  const resolved = posix.normalize(posix.join(baseDir, rawPath)).replace(/^\.\//, "");

  const docMatch = /^docs\/(?:(?:en|zh)\/)?([a-z0-9-]+)\.md$/i.exec(resolved);
  if (docMatch && docSlugs.has(docMatch[1]!)) {
    return `../${docMatch[1]!}/${hash}`;
  }

  return `${REPO_BLOB_BASE}/${resolved}${hash}`;
}

const ALERT_LABELS: Record<Locale, Record<string, string>> = {
  en: {
    note: "Note",
    tip: "Tip",
    important: "Important",
    warning: "Warning",
    caution: "Caution",
  },
  zh: {
    note: "说明",
    tip: "提示",
    important: "重要",
    warning: "注意",
    caution: "警示",
  },
};

export function transformAlerts(html: string, locale: Locale): string {
  return html.replace(/<blockquote>\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:<br\s*\/?>|\s*\n|\s*<\/p>\s*)([\s\S]*?)<\/blockquote>/gi, (_, rawKind: string, rest: string) => {
    const kind = rawKind.toLowerCase();
    const label = ALERT_LABELS[locale][kind] ?? rawKind;
    const trimmed = rest.trim();
    const body = trimmed.startsWith("<p>") || trimmed.startsWith("<ul>") || trimmed.startsWith("<ol>")
      ? trimmed
      : `<p>${trimmed}`;
    return `<div class="doc-alert doc-alert-${kind}" role="note"><p class="doc-alert-title">${label}</p><div class="doc-alert-body">${body}</div></div>`;
  });
}

export function renderDocMarkdown(markdown: string, sourceRepoRelPath: string, locale: Locale): RenderedDoc {
  const cleaned = stripDocPreamble(markdown);

  // 提取第一行 H1 作为文档主标题，避免正文与页头重复
  let title = "";
  const bodyMarkdown = cleaned.replace(/^#\s+(.+?)\s*(?:\n+|$)/, (_, heading: string) => {
    title = heading.trim();
    return "";
  });

  let html = Bun.markdown.html(bodyMarkdown, {
    tables: true,
    strikethrough: true,
    tasklists: true,
    autolinks: true,
  });

  // 先把 <pre>...</pre> 抽成占位符，避免后续正则误改代码示例里的内容
  const codeBlocks: string[] = [];
  const copyLabel = locale === "zh" ? "复制" : "Copy";
  const copiedLabel = locale === "zh" ? "已复制" : "Copied";
  const copiedStatus = locale === "zh" ? "已复制代码块" : "Code copied.";
  const copyFailed = locale === "zh" ? "无法自动复制，请选中代码手动复制。" : "Select the code and copy it manually.";
  const copyAria = locale === "zh" ? "复制代码" : "Copy code";

  html = html.replace(/<pre><code(?: class="language-([^"]+)")?>([\s\S]*?)<\/code><\/pre>/g, (match, lang: string | undefined) => {
    const idx = codeBlocks.length;
    const langTag = lang ? `<span class="doc-code-lang">${escapeHtml(lang)}</span>` : `<span class="doc-code-lang"></span>`;
    const wrapped = [
      `<div class="doc-code-block">`,
      `<div class="doc-code-bar">${langTag}<button class="code-copy" type="button" data-copy-code aria-label="${copyAria}" data-copied="${copiedStatus}" data-copied-button="${copiedLabel}" data-copy-failed="${copyFailed}" hidden>${copyLabel}</button></div>`,
      match,
      `<span class="visually-hidden" role="status" data-copy-status></span>`,
      `</div>`,
    ].join("");
    codeBlocks.push(wrapped);
    return `<!--CODE_BLOCK_${idx}-->`;
  });

  // GitHub 风格 Alert
  html = transformAlerts(html, locale);

  // 标题锚点与右侧目录提取（避开页面固定布局 id）
  const usedSlugs = new Map<string, number>([
    ["nav", 1],
    ["theme-toggle", 1],
    ["top", 1],
    ["doc-page-title", 1],
  ]);
  const toc: TocItem[] = [];
  const anchorAria = locale === "zh" ? "此节链接" : "Link to this section";

  html = html.replace(/<h([234])(?:\s+[^>]*)?>([\s\S]*?)<\/h\1>/g, (_, levelStr: string, inner: string) => {
    const level = Number(levelStr);
    const plainText = decodeHtmlEntities(inner.replace(/<[^>]+>/g, "")).trim();
    const baseSlug = slugifyHeading(inner) || `section-${toc.length + 1}`;
    const count = usedSlugs.get(baseSlug) ?? 0;
    usedSlugs.set(baseSlug, count + 1);
    const id = count === 0 ? baseSlug : `${baseSlug}-${count}`;

    if (level === 2 || level === 3) {
      toc.push({ level, id, text: plainText });
      return `<h${level} id="${escapeHtml(id)}">${inner}<a class="doc-heading-anchor" href="#${escapeHtml(id)}" aria-label="${anchorAria}">#</a></h${level}>`;
    }
    return `<h${level} id="${escapeHtml(id)}">${inner}</h${level}>`;
  });

  // 重写文档内相对链接
  html = html.replace(/<a\b([^>]*?)\bhref="([^"]+)"([^>]*)>/g, (_, before: string, href: string, after: string) => {
    const rewritten = rewriteDocHref(href, sourceRepoRelPath);
    return `<a${before}href="${escapeHtml(rewritten)}"${after}>`;
  });

  // 表格响应式包裹
  html = html.replace(/<table>([\s\S]*?)<\/table>/g, '<div class="doc-table-wrap"><table>$1</table></div>');

  // 还原代码块
  html = html.replace(/<!--CODE_BLOCK_(\d+)-->/g, (_, idx: string) => codeBlocks[Number(idx)] ?? "");

  return { title: title || "Tacit", html, toc };
}

function renderRootRedirectPage(): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tacit | Give AI the context it needs</title>
  <meta name="description" content="Tacit turns AI sessions, chats and recordings into a daily timeline. Review your decisions and give AI tools your context through MCP.">
  <meta name="theme-color" content="#fbfaf7" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#181716" media="(prefers-color-scheme: dark)">
  <meta http-equiv="refresh" content="0; url=en/">
  <link rel="canonical" href="${SITE_ORIGIN}/en/">
  <link rel="alternate" hreflang="en" href="${SITE_ORIGIN}/en/">
  <link rel="alternate" hreflang="zh-CN" href="${SITE_ORIGIN}/zh/">
  <link rel="alternate" hreflang="x-default" href="${SITE_ORIGIN}/en/">
  <link rel="icon" href="assets/favicon.ico" sizes="any">
  <link rel="icon" href="assets/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="apple-touch-icon" href="assets/apple-touch-icon.png">
  <script>
    (() => {
      let lang = null;
      try {
        const saved = localStorage.getItem("tacit-lang");
        if (saved === "zh" || saved === "en") lang = saved;
      } catch {}
      if (!lang) {
        const langs = (navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language]).filter(Boolean);
        const primary = String(langs[0] || "").toLowerCase();
        lang = primary.startsWith("zh") ? "zh" : "en";
      }
      const suffix = location.protocol === "file:" ? "index.html" : "";
      const target = (lang === "zh" ? "zh/" : "en/") + suffix;
      location.replace(target + location.search + location.hash);
    })();
  </script>
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0;
      min-height: 100svh;
      display: grid;
      place-items: center;
      padding: 24px;
      background: #fbfaf7;
      color: #1c1b1a;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
    }
    @media (prefers-color-scheme: dark) {
      body { background: #181716; color: #f2efea; }
    }
    main { text-align: center; display: grid; gap: 16px; }
    h1 { margin: 0; font-family: Georgia, serif; font-size: 24px; font-weight: 400; }
    nav { display: flex; justify-content: center; gap: 20px; }
    a { color: #3b7468; text-decoration: underline; text-underline-offset: 4px; }
    @media (prefers-color-scheme: dark) {
      a { color: #7db8a9; }
    }
  </style>
</head>
<body>
  <main>
    <h1>Tacit</h1>
    <nav aria-label="Language">
      <a href="en/" hreflang="en" lang="en">English</a>
      <a href="zh/" hreflang="zh-CN" lang="zh-CN">简体中文</a>
    </nav>
  </main>
</body>
</html>
`;
}

function renderDocsShell(options: {
  locale: Locale;
  pageTitle: string;
  description: string;
  routePath: string; // e.g. "docs/" or "docs/trial-guide/"
  activeSlug: DocSlug | "index";
  contentHtml: string;
  toc?: TocItem[];
  mobileCurrentLabel: string;
}): string {
  const { locale, pageTitle, description, routePath, activeSlug, contentHtml, toc = [], mobileCurrentLabel } = options;
  const isArticle = activeSlug !== "index";
  const isZh = locale === "zh";
  const otherLocale: Locale = isZh ? "en" : "zh";
  const htmlLang = isZh ? "zh-CN" : "en";
  const ogLocale = isZh ? "zh_CN" : "en_US";
  const ogAltLocale = isZh ? "en_US" : "zh_CN";
  const ogImage = isZh ? `${SITE_ORIGIN}/assets/og-cover.png` : `${SITE_ORIGIN}/assets/og-cover-en.png`;

  // 相对当前页到本语言根、下载页、文档根、另一语言同路由的路径
  const homeHref = isArticle ? "../../" : "../";
  const downloadHref = isArticle ? "../../download/" : "../download/";
  const docsIndexHref = isArticle ? "../" : "./";
  const altLangHref = isArticle ? `../../../${otherLocale}/${routePath}` : `../../${otherLocale}/${routePath}`;

  const docHref = (slug: DocSlug) => (isArticle ? `../${slug}/` : `${slug}/`);

  const navLabels = isZh
    ? {
        homeAria: "Tacit 首页",
        navAria: "页面导航",
        timeline: "时间线",
        ai: "接续 AI",
        privacy: "隐私",
        download: "下载",
        docs: "文档",
        langLabel: "Switch to English",
        langHreflang: "en",
        themeAria: "切换深浅色外观",
        themeLight: "切换到浅色外观",
        themeDark: "切换到深色外观",
        sidebarTitle: "文档目录",
        overview: "文档概览",
        tocTitle: "本页目录",
        footerTagline: "把每天的对话与活动整理成时间线，让任意 AI 接上你的上下文。",
        footerAria: "页脚链接",
        releases: "版本记录",
        license: "许可证",
      }
    : {
        homeAria: "Tacit home",
        navAria: "Page navigation",
        timeline: "Timeline",
        ai: "Session context",
        privacy: "Privacy",
        download: "Download",
        docs: "Docs",
        langLabel: "切换到中文",
        langHreflang: "zh-CN",
        themeAria: "Switch color theme",
        themeLight: "Switch to light theme",
        themeDark: "Switch to dark theme",
        sidebarTitle: "Documentation",
        overview: "Overview",
        tocTitle: "On this page",
        footerTagline: "A timeline for your day. Context for your AI tools.",
        footerAria: "Footer links",
        releases: "Releases",
        license: "License",
      };

  const sidebarItems = [
    `<li><a class="doc-nav-link" href="${docsIndexHref}"${activeSlug === "index" ? ' aria-current="page"' : ""}>${navLabels.overview}</a></li>`,
    ...DOCS.map(
      (doc) =>
        `<li><a class="doc-nav-link" href="${docHref(doc.slug)}"${activeSlug === doc.slug ? ' aria-current="page"' : ""}>${escapeHtml(doc.navTitle[locale])}</a></li>`,
    ),
  ].join("\n              ");

  const tocHtml =
    isArticle && toc.length > 0
      ? `<aside class="doc-toc" aria-label="${navLabels.tocTitle}">
          <p class="doc-toc-title">${navLabels.tocTitle}</p>
          <ul class="doc-toc-list">
            ${toc
              .map(
                (item) =>
                  `<li data-level="${item.level}"><a href="#${escapeHtml(item.id)}">${escapeHtml(item.text)}</a></li>`,
              )
              .join("\n            ")}
          </ul>
        </aside>`
      : "";

  const canonicalUrl = `${SITE_ORIGIN}/${locale}/${routePath}`;
  const enUrl = `${SITE_ORIGIN}/en/${routePath}`;
  const zhUrl = `${SITE_ORIGIN}/zh/${routePath}`;

  return `<!doctype html>
<html lang="${htmlLang}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(pageTitle)} | Tacit</title>
  <meta name="description" content="${escapeHtml(description)}">
  <meta name="theme-color" content="#fbfaf7" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#181716" media="(prefers-color-scheme: dark)">
  <meta property="og:title" content="${escapeHtml(pageTitle)} | Tacit">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:type" content="website">
  <meta property="og:url" content="${canonicalUrl}">
  <meta property="og:locale" content="${ogLocale}">
  <meta property="og:locale:alternate" content="${ogAltLocale}">
  <link rel="canonical" href="${canonicalUrl}">
  <link rel="alternate" hreflang="en" href="${enUrl}">
  <link rel="alternate" hreflang="zh-CN" href="${zhUrl}">
  <link rel="alternate" hreflang="x-default" href="${enUrl}">
  <meta property="og:image" content="${ogImage}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:image" content="${ogImage}">
  <link rel="icon" href="assets/favicon.ico" sizes="any">
  <link rel="icon" href="assets/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="apple-touch-icon" href="assets/apple-touch-icon.png">
  <script type="module" src="scripts/platform.js"></script>
  <link rel="stylesheet" href="styles/base.css">
  <link rel="stylesheet" href="styles/docs.css">
</head>
<body>
  <header class="nav" id="nav">
    <div class="wrap nav-inner">
      <a class="brand" href="${homeHref}" aria-label="${navLabels.homeAria}"><img src="assets/mark.svg" alt="">Tacit</a>
      <nav class="nav-links" aria-label="${navLabels.navAria}">
        <a href="${homeHref}#day" data-nav-anchor>${navLabels.timeline}</a>
        <a href="${homeHref}#ai" data-nav-anchor>${navLabels.ai}</a>
        <a href="${homeHref}#privacy" data-nav-anchor>${navLabels.privacy}</a>
        <a href="${downloadHref}" data-nav-download>${navLabels.download}</a>
        <a href="${docsIndexHref}" aria-current="page">${navLabels.docs}</a>
      </nav>
      <div class="nav-actions">
        <a class="icon-btn nav-lang" href="${altLangHref}" hreflang="${navLabels.langHreflang}" lang="${navLabels.langHreflang}" data-lang-switch="${otherLocale}" aria-label="${navLabels.langLabel}" title="${navLabels.langLabel}">
          <svg aria-hidden="true"><use href="assets/sources.svg#lang"/></svg>
        </a>
        <button class="icon-btn theme-toggle" type="button" id="theme-toggle" aria-label="${navLabels.themeAria}" title="${navLabels.themeAria}"
          data-light-label="${navLabels.themeLight}" data-dark-label="${navLabels.themeDark}" hidden>
          <svg class="icon-sun" aria-hidden="true"><use href="assets/sources.svg#sun"/></svg>
          <svg class="icon-moon" aria-hidden="true"><use href="assets/sources.svg#moon"/></svg>
        </button>
        <a class="btn btn-primary" href="${downloadHref}">${navLabels.download}</a>
      </div>
    </div>
  </header>

  <main id="top" class="docs-page">
    <div class="wrap">
      <details class="doc-mobile-nav">
        <summary>${escapeHtml(navLabels.sidebarTitle)} · ${escapeHtml(mobileCurrentLabel)}</summary>
        <ul class="doc-mobile-nav-list">
          ${sidebarItems}
        </ul>
      </details>

      <div class="docs-shell${isArticle ? " docs-shell-article" : ""}">
        <aside class="doc-sidebar" aria-label="${navLabels.sidebarTitle}">
          <p class="doc-sidebar-title">${navLabels.sidebarTitle}</p>
          <ul class="doc-nav-list">
            ${sidebarItems}
          </ul>
        </aside>

        ${contentHtml}
        ${tocHtml}
      </div>
    </div>
  </main>

  <footer class="footer">
    <div class="wrap footer-inner caption">
      <a class="brand" href="${homeHref}"><img src="assets/mark.svg" alt="">Tacit</a>
      <span>${navLabels.footerTagline}</span>
      <nav class="footer-links" aria-label="${navLabels.footerAria}">
        <a href="${downloadHref}">${navLabels.download}</a>
        <a href="${docsIndexHref}">${navLabels.docs}</a>
        <a href="https://github.com/JinSooo/tacit">GitHub</a>
        <a href="https://github.com/JinSooo/tacit/releases">${navLabels.releases}</a>
        <a href="https://github.com/JinSooo/tacit/blob/main/LICENSE">${navLabels.license}</a>
      </nav>
    </div>
  </footer>

  <script type="module" src="scripts/main.js"></script>
</body>
</html>
`;
}

function renderDocsIndexPage(locale: Locale): string {
  const isZh = locale === "zh";
  const pageTitle = isZh ? "文档" : "Documentation";
  const description = isZh
    ? "Tacit 使用指南：快速上手、常见问题排查、Docker 服务端部署、安装与发布以及数据源插件说明。"
    : "Tacit documentation: getting started, troubleshooting, Docker server deployment, installation & releases, and source plugins.";
  const lead = isZh
    ? "从 5 分钟试用说明开始，或查阅常见问题排查、Docker 独立部署和插件规格。"
    : "Start with the 5-minute guide, or read troubleshooting, Docker deployment and plugin specifications.";

  const cards = DOCS.map(
    (doc) => `<a class="doc-index-card" href="${doc.slug}/">
            <h2>${escapeHtml(doc.navTitle[locale])}</h2>
            <p>${escapeHtml(doc.summary[locale])}</p>
          </a>`,
  ).join("\n          ");

  const contentHtml = `<section class="doc-index" aria-labelledby="docs-index-heading">
          <header class="doc-index-head">
            <h1 class="heading" id="docs-index-heading">${escapeHtml(pageTitle)}</h1>
            <p class="lead">${escapeHtml(lead)}</p>
          </header>
          <div class="doc-index-grid">
            ${cards}
          </div>
          <div class="doc-index-foot caption">
            <a class="link" href="../download/">${isZh ? "前往下载页" : "Go to downloads"}</a>
            <a class="link" href="https://github.com/JinSooo/tacit/issues">${isZh ? "在 GitHub 提交反馈" : "Report an issue on GitHub"}</a>
          </div>
        </section>`;

  return renderDocsShell({
    locale,
    pageTitle,
    description,
    routePath: "docs/",
    activeSlug: "index",
    contentHtml,
    mobileCurrentLabel: isZh ? "文档概览" : "Overview",
  });
}

function renderDocArticlePage(locale: Locale, docIndex: number): string {
  const meta = DOCS[docIndex]!;
  const isZh = locale === "zh";
  const sourceRel = resolveDocSource(repoRoot, locale, meta.slug);
  const rawMarkdown = readFileSync(join(repoRoot, sourceRel), "utf8");
  const rendered = renderDocMarkdown(rawMarkdown, sourceRel, locale);

  const prev = docIndex > 0 ? DOCS[docIndex - 1]! : null;
  const next = docIndex < DOCS.length - 1 ? DOCS[docIndex + 1]! : null;

  const pagerHtml =
    prev || next
      ? `<nav class="doc-pager" aria-label="${isZh ? "上一篇与下一篇" : "Previous and next guide"}">
            ${
              prev
                ? `<a href="../${prev.slug}/"><span class="doc-pager-label">${isZh ? "上一篇" : "Previous"}</span><span class="doc-pager-title">${escapeHtml(prev.navTitle[locale])}</span></a>`
                : ""
            }
            ${
              next
                ? `<a class="doc-pager-next" href="../${next.slug}/"><span class="doc-pager-label">${isZh ? "下一篇" : "Next"}</span><span class="doc-pager-title">${escapeHtml(next.navTitle[locale])}</span></a>`
                : ""
            }
          </nav>`
      : "";

  const contentHtml = `<article class="doc-article" aria-labelledby="doc-page-title">
          <header class="doc-article-header">
            <h1 id="doc-page-title">${escapeHtml(rendered.title)}</h1>
          </header>
          <div class="doc-prose">
            ${rendered.html}
          </div>
          ${pagerHtml}
        </article>`;

  return renderDocsShell({
    locale,
    pageTitle: rendered.title,
    description: meta.summary[locale],
    routePath: `docs/${meta.slug}/`,
    activeSlug: meta.slug,
    contentHtml,
    toc: rendered.toc,
    mobileCurrentLabel: meta.navTitle[locale],
  });
}

interface PageAudit {
  ids: Set<string>;
  sections: string[];
  downloads: string[];
  internalRefs: Array<{ attr: string; value: string }>;
}

function auditHtmlPage(pagePath: string, html: string): PageAudit {
  const ids = new Set<string>();
  const sections: string[] = [];
  const downloads: string[] = [];
  const internalRefs: Array<{ attr: string; value: string }> = [];

  new HTMLRewriter()
    .on("[id]", {
      element(element) {
        const id = element.getAttribute("id")!;
        if (ids.has(id)) throw new Error(`${pagePath} 存在重复的 id：${id}`);
        ids.add(id);
      },
    })
    .on("main > section", {
      element(element) {
        const id = element.getAttribute("id");
        if (id) sections.push(id);
      },
    })
    .on("a[data-platform-target]", {
      element(element) {
        downloads.push(`${element.getAttribute("data-platform-target")} ${element.getAttribute("href")}`);
      },
    })
    .on("a[href]", {
      element(element) {
        const href = element.getAttribute("href");
        if (href) internalRefs.push({ attr: "href", value: href });
      },
    })
    .on("link[href]", {
      element(element) {
        const rel = element.getAttribute("rel");
        if (rel === "canonical" || rel === "alternate") return;
        const href = element.getAttribute("href");
        if (href) internalRefs.push({ attr: "href", value: href });
      },
    })
    .on("img[src]", {
      element(element) {
        const srcAttr = element.getAttribute("src");
        if (srcAttr) internalRefs.push({ attr: "src", value: srcAttr });
      },
    })
    .on("source[srcset]", {
      element(element) {
        const srcset = element.getAttribute("srcset");
        if (srcset) internalRefs.push({ attr: "srcset", value: srcset.split(",")[0]!.trim().split(/\s+/)[0]! });
      },
    })
    .transform(html);

  return { ids, sections, downloads, internalRefs };
}

function assertParity(label: string, zh: string[], en: string[]) {
  if (JSON.stringify(zh) !== JSON.stringify(en)) {
    throw new Error(`中英文${label}不一致\nzh: ${zh.join(", ")}\nen: ${en.join(", ")}`);
  }
}

export function build(): BuildResult {
  const latest = JSON.parse(readFileSync(join(src, "latest.json"), "utf8")) as {
    mac: { version: string; url: string };
  };
  if (!latest?.mac?.version || !latest?.mac?.url) {
    throw new Error("site/src/latest.json 缺少 mac.version 或 mac.url");
  }

  const zhSectionFiles = readdirSync(join(src, "zh/sections")).filter((name) => name.endsWith(".html")).sort();
  const enSectionFiles = readdirSync(join(src, "en/sections")).filter((name) => name.endsWith(".html")).sort();
  assertParity("首页区块文件", zhSectionFiles, enSectionFiles);

  const builtPages = new Map<string, string>();
  builtPages.set("index.html", renderRootRedirectPage());

  const homeAudits: Record<Locale, PageAudit> = {} as Record<Locale, PageAudit>;
  const downloadAudits: Record<Locale, PageAudit> = {} as Record<Locale, PageAudit>;

  for (const locale of ["en", "zh"] as const) {
    // 1. Home page: /en/ & /zh/
    const homeRaw = expand(join(src, locale, "index.html"));
    const homeHtml = inline(homeRaw, "../");
    builtPages.set(`${locale}/index.html`, homeHtml);
    homeAudits[locale] = auditHtmlPage(`${locale}/index.html`, homeHtml);

    // 2. Download page: /en/download/ & /zh/download/
    const downloadRaw = expand(join(src, locale, "download.html"));
    const downloadHtml = inline(downloadRaw, "../../");
    builtPages.set(`${locale}/download/index.html`, downloadHtml);
    downloadAudits[locale] = auditHtmlPage(`${locale}/download/index.html`, downloadHtml);

    // 3. Docs index page: /en/docs/ & /zh/docs/
    const docsIndexHtml = inline(renderDocsIndexPage(locale), "../../");
    builtPages.set(`${locale}/docs/index.html`, docsIndexHtml);

    // 4. Docs article pages: /en/docs/<slug>/ & /zh/docs/<slug>/
    for (let i = 0; i < DOCS.length; i += 1) {
      const slug = DOCS[i]!.slug;
      const articleHtml = inline(renderDocArticlePage(locale, i), "../../../");
      builtPages.set(`${locale}/docs/${slug}/index.html`, articleHtml);
    }
  }

  // 校验中英文路由集合完全一致
  const enRoutes = [...builtPages.keys()].filter((p) => p.startsWith("en/")).map((p) => p.slice(3)).sort();
  const zhRoutes = [...builtPages.keys()].filter((p) => p.startsWith("zh/")).map((p) => p.slice(3)).sort();
  assertParity("路由集合", zhRoutes, enRoutes);

  // 校验首页和下载页结构与下载链接一致
  assertParity("首页区块顺序", homeAudits.zh.sections, homeAudits.en.sections);
  assertParity("首页元素 id", [...homeAudits.zh.ids].sort(), [...homeAudits.en.ids].sort());
  assertParity("首页版本下载链接", homeAudits.zh.downloads, homeAudits.en.downloads);
  assertParity("下载页元素 id", [...downloadAudits.zh.ids].sort(), [...downloadAudits.en.ids].sort());
  assertParity("下载页版本下载链接", downloadAudits.zh.downloads, downloadAudits.en.downloads);

  // 校验所有页面无重复 ID、无未展开标记，且 Mac 下载链接与 latest.json 一致
  const allAudits = new Map<string, PageAudit>();
  let totalDownloadLinks = 0;
  for (const [pagePath, html] of builtPages) {
    const missing = html.match(/<!--\s*include:[^>]*-->|type="module"|sources\.svg#|<!--CODE_BLOCK_\d+-->/);
    if (missing) throw new Error(`${pagePath} 存在未处理的引用：${missing[0]}`);

    const audit = auditHtmlPage(pagePath, html);
    allAudits.set(pagePath, audit);

    for (const entry of audit.downloads) {
      totalDownloadLinks += 1;
      const [target, href] = entry.split(" ");
      if (target === "mac" && href !== latest.mac.url) {
        throw new Error(`${pagePath} 的 Mac 下载链接 (${href}) 与 latest.json (${latest.mac.url}) 不一致`);
      }
    }
  }

  // 校验所有站内相对链接目标及锚点均存在
  const assetFiles = new Set<string>();
  const collectAssets = (dir: string, prefix = "") => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) collectAssets(join(dir, entry.name), rel);
      else assetFiles.add(`assets/${rel}`);
    }
  };
  collectAssets(join(src, "assets"));

  let checkedLinks = 0;
  for (const [pagePath, audit] of allAudits) {
    const pageDir = posix.dirname(pagePath);
    for (const ref of audit.internalRefs) {
      const value = ref.value;
      if (/^(?:https?:|mailto:|tel:|data:|javascript:)/i.test(value)) continue;
      checkedLinks += 1;

      const hashIdx = value.indexOf("#");
      const rawPath = hashIdx >= 0 ? value.slice(0, hashIdx) : value;
      const rawHash = hashIdx >= 0 ? value.slice(hashIdx + 1) : "";

      let targetPage = pagePath;
      if (rawPath) {
        let joined = posix.normalize(pageDir === "." ? rawPath : posix.join(pageDir, rawPath));
        if (joined.startsWith("../")) {
          throw new Error(`${pagePath} 的站内链接越出站点根目录：${value}`);
        }
        if (joined === "." || joined === "") {
          joined = "index.html";
        } else if (joined.endsWith("/")) {
          joined += "index.html";
        } else if (!builtPages.has(joined) && !assetFiles.has(joined) && builtPages.has(`${joined}/index.html`)) {
          joined = `${joined}/index.html`;
        }

        if (!builtPages.has(joined) && !assetFiles.has(joined) && joined !== "latest.json") {
          throw new Error(`${pagePath} 存在无效站内链接：${value}（解析为 ${joined}）`);
        }
        targetPage = joined;
      }

      if (rawHash) {
        const targetAudit = allAudits.get(targetPage);
        if (!targetAudit) {
          throw new Error(`${pagePath} 的锚点链接指向非 HTML 文件：${value}`);
        }
        const decodedHash = decodeURIComponent(rawHash);
        if (!targetAudit.ids.has(decodedHash)) {
          throw new Error(`${pagePath} 存在无效锚点：${value}（${targetPage} 中缺少 id="${decodedHash}"）`);
        }
      }
    }
  }

  // 写出产物
  rmSync(dist, { recursive: true, force: true });
  mkdirSync(dist, { recursive: true });
  cpSync(join(src, "assets"), join(dist, "assets"), { recursive: true });
  // Mac 应用每天读一次，判断有没有新版本（collector UpdateManifest）。
  cpSync(join(src, "latest.json"), join(dist, "latest.json"));

  for (const [pagePath, html] of builtPages) {
    const outPath = join(dist, pagePath);
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, html);
  }

  const result: BuildResult = {
    pages: [...builtPages.keys()].sort(),
    homeSections: homeAudits.en.sections.length,
    homeIds: homeAudits.en.ids.size,
    downloadIds: downloadAudits.en.ids.size,
    downloadLinks: totalDownloadLinks,
    docCount: DOCS.length,
    checkedLinks,
  };

  console.log(
    `构建校验通过：${result.pages.length} 个页面（中英文各 ${enRoutes.length} 路由，含 ${result.docCount} 篇文档）、` +
      `首页 ${result.homeSections} 区块 / ${result.homeIds} id、下载页 ${result.downloadIds} id、` +
      `校验 ${result.checkedLinks} 个站内链接无死链`,
  );

  return result;
}

export type ServeResolution =
  | { kind: "redirect"; location: string }
  | { kind: "file"; relPath: string; isHtml: boolean }
  | { kind: "not-found" };

export function resolveServeTarget(pathname: string, search: string, distDir: string): ServeResolution {
  const normalized = posix.normalize(pathname);
  if (normalized.includes("..")) return { kind: "not-found" };

  if (normalized === "/") {
    return { kind: "file", relPath: "index.html", isHtml: true };
  }

  const trimmed = normalized.replace(/^\/+/, "");
  if (normalized.endsWith("/")) {
    const candidate = `${trimmed}index.html`;
    return existsSync(join(distDir, candidate))
      ? { kind: "file", relPath: candidate, isHtml: true }
      : { kind: "not-found" };
  }

  // 无尾斜杠的干净目录路由（例如 /en、/en/download、/en/docs/trial-guide）重定向到带尾斜杠地址，确保相对链接准确解析
  if (existsSync(join(distDir, trimmed, "index.html"))) {
    return { kind: "redirect", location: `${normalized}/${search}` };
  }

  if (existsSync(join(distDir, trimmed))) {
    return { kind: "file", relPath: trimmed, isHtml: trimmed.endsWith(".html") };
  }

  return { kind: "not-found" };
}

if (import.meta.main) {
  build();
  console.log(`已构建 ${dist}`);

  if (process.argv.includes("--serve")) {
    const port = Number(process.env.PORT ?? 4300);
    Bun.serve({
      port,
      hostname: "127.0.0.1",
      fetch(req) {
        const url = new URL(req.url);
        let resolution = resolveServeTarget(url.pathname, url.search, dist);
        if (resolution.kind === "file" && resolution.isHtml) {
          build();
          resolution = resolveServeTarget(url.pathname, url.search, dist);
        } else if (resolution.kind === "redirect") {
          return Response.redirect(new URL(resolution.location, url.origin), 302);
        }

        if (resolution.kind !== "file") {
          return new Response("Not Found", { status: 404 });
        }

        const file = Bun.file(join(dist, resolution.relPath));
        return file.size ? new Response(file) : new Response("Not Found", { status: 404 });
      },
    });
    console.log(`预览 http://127.0.0.1:${port}`);
  }
}
