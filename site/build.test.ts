import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  applyReleaseTokens,
  auditHtmlPage,
  build,
  DOCS,
  readReleaseVersions,
  renderDocMarkdown,
  resolveDocSource,
  resolveServeTarget,
  rewriteDocHref,
  sanitizeDocHtml,
  slugifyHeading,
  stripDocPreamble,
} from "./build.ts";

const siteDir = import.meta.dir;
const repoRoot = join(siteDir, "..");
const distDir = join(siteDir, "dist");
const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("site/build.ts 多页官网与文档站构建", () => {
  const result = build();

  test("生成全部预期路由与根路径 latest.json", () => {
    const expectedFiles = [
      "index.html",
      "latest.json",
      "en/index.html",
      "zh/index.html",
      "en/download/index.html",
      "zh/download/index.html",
      "en/docs/index.html",
      "zh/docs/index.html",
      ...DOCS.flatMap((doc) => [`en/docs/${doc.slug}/index.html`, `zh/docs/${doc.slug}/index.html`]),
    ];

    for (const rel of expectedFiles) {
      expect(existsSync(join(distDir, rel))).toBe(true);
    }

    expect(readFileSync(join(distDir, "latest.json"), "utf8")).toBe(
      readFileSync(join(siteDir, "src/latest.json"), "utf8"),
    );
    expect(result.docCount).toBe(5);
    expect(result.pages.length).toBe(1 + 2 * (1 + 1 + 1 + DOCS.length));
  });

  test("根路径 index.html 的 JS 语言分流保留 query/hash，静态无 JS 回落指向 en/", () => {
    const rootHtml = readFileSync(join(distDir, "index.html"), "utf8");
    // JS 语言分流分支（保留 search 与 hash）
    expect(rootHtml).toContain('localStorage.getItem("tacit-lang")');
    expect(rootHtml).toContain("navigator.languages");
    expect(rootHtml).toContain('primary.startsWith("zh")');
    expect(rootHtml).toContain("location.replace(target + location.search + location.hash)");
    // 静态无 JS 回落（纯静态 HTML 仅跳转至默认英文首页，不拼接 query/hash）
    expect(rootHtml).toContain('<meta http-equiv="refresh" content="0; url=en/">');
    expect(rootHtml).toContain('<link rel="canonical" href="https://tacit.jinso.top/en/">');
    expect(rootHtml).toContain('<link rel="alternate" hreflang="en" href="https://tacit.jinso.top/en/">');
    expect(rootHtml).toContain('<link rel="alternate" hreflang="zh-CN" href="https://tacit.jinso.top/zh/">');
    expect(rootHtml).toContain('<link rel="alternate" hreflang="x-default" href="https://tacit.jinso.top/en/">');
    expect(rootHtml).toContain('href="en/"');
    expect(rootHtml).toContain('href="zh/"');
  });

  test("顶栏采用图标化语言/主题切换、去除顶部语言横幅并保持同页语言互链", () => {
    const checks: Array<{ file: string; altHref: string; switchLang: string }> = [
      { file: "en/index.html", altHref: "../zh/", switchLang: "zh" },
      { file: "zh/index.html", altHref: "../en/", switchLang: "en" },
      { file: "en/download/index.html", altHref: "../../zh/download/", switchLang: "zh" },
      { file: "zh/download/index.html", altHref: "../../en/download/", switchLang: "en" },
      { file: "en/docs/index.html", altHref: "../../zh/docs/", switchLang: "zh" },
      { file: "zh/docs/index.html", altHref: "../../en/docs/", switchLang: "en" },
      { file: "en/docs/troubleshooting/index.html", altHref: "../../../zh/docs/troubleshooting/", switchLang: "zh" },
      { file: "zh/docs/troubleshooting/index.html", altHref: "../../../en/docs/troubleshooting/", switchLang: "en" },
    ];

    for (const { file, altHref, switchLang } of checks) {
      const html = readFileSync(join(distDir, file), "utf8");
      expect(html).not.toContain("language-notice");
      expect(html).toContain(`href="${altHref}"`);
      expect(html).toContain(`data-lang-switch="${switchLang}"`);
      expect(html).toContain('href="#src-lang"');
      expect(html).toContain('href="#src-sun"');
      expect(html).toContain('href="#src-moon"');
      expect(html).not.toMatch(/fonts\.googleapis\.com|cdn\.jsdelivr|unpkg\.com|cdnjs\.cloudflare/i);
    }
  });

  test("首页采用按设备匹配的单一主下载按钮与站内文档链接", () => {
    for (const locale of ["en", "zh"] as const) {
      const html = readFileSync(join(distDir, `${locale}/index.html`), "utf8");
      expect(html).toContain("data-platform-single");
      expect(html).toContain('data-platform-cta="mac"');
      expect(html).toContain('data-platform-cta="android"');
      expect(html).toContain('data-platform-cta="other"');
      expect(html).toContain('href="download/"');
      expect(html).toContain('href="docs/server-deployment/"');
      expect(html).toContain('href="download/#download-open"');
      expect(html).not.toContain("https://github.com/JinSooo/tacit/blob/main/docs/server-deployment.md");
    }
  });

  test("独立下载页从实时版本源派生 Mac、Android、Docker 链接与文件名", () => {
    const versions = readReleaseVersions(repoRoot);
    for (const locale of ["en", "zh"] as const) {
      const html = readFileSync(join(distDir, `${locale}/download/index.html`), "utf8");
      expect(html).toContain(`href="${versions.mac.download}"`);
      expect(versions.mac.download).toBe(`https://github.com/JinSooo/tacit/releases/download/mac-v${versions.mac.version}/Tacit-${versions.mac.version}.dmg`);
      expect(html).toContain(`Tacit-${versions.mac.version}.dmg`);
      expect(html).toContain(`href="${versions.android.download}"`);
      expect(html).not.toContain(`href="${versions.mac.url}"`);
      expect(html).toContain(`Tacit-${versions.android.version}.apk`);
      expect(html).toContain(`docker pull ghcr.io/jinsooo/tacit-hub:${versions.hub.version}`);
      expect(html).toContain("xattr -dr com.apple.quarantine /Applications/Tacit.app");
      expect(html).toContain('href="../docs/server-deployment/"');
      expect(html).toContain('href="https://github.com/JinSooo/tacit/releases"');
      expect(html).toContain('aria-current="page"');
      expect(html).not.toMatch(/\{\{[A-Z0-9_]+\}\}/);
    }
  });

  test("两端版本号独立变更时 applyReleaseTokens 正确生成各自链接与摘要", () => {
    const template = "{{RELEASE_SUMMARY}}|{{MAC_RELEASE_URL}}|{{MAC_DOWNLOAD_URL}}|{{ANDROID_RELEASE_URL}}|{{ANDROID_DOWNLOAD_URL}}|{{HUB_VERSION}}";
    const rendered = applyReleaseTokens(template, {
      mac: { version: "0.8.0", tag: "mac-v0.8.0", url: "https://github.com/JinSooo/tacit/releases/tag/mac-v0.8.0",
        download: "https://github.com/JinSooo/tacit/releases/download/mac-v0.8.0/Tacit-0.8.0.dmg" },
      android: { version: "0.7.2", tag: "android-v0.7.2", url: "https://github.com/JinSooo/tacit/releases/tag/android-v0.7.2",
        download: "https://github.com/JinSooo/tacit/releases/download/android-v0.7.2/Tacit-0.7.2.apk" },
      hub: { version: "0.8.0" },
      summary: "Mac v0.8.0 · Android v0.7.2",
    });
    expect(rendered).toBe(
      "Mac v0.8.0 · Android v0.7.2|https://github.com/JinSooo/tacit/releases/tag/mac-v0.8.0|https://github.com/JinSooo/tacit/releases/download/mac-v0.8.0/Tacit-0.8.0.dmg"
        + "|https://github.com/JinSooo/tacit/releases/tag/android-v0.7.2|https://github.com/JinSooo/tacit/releases/download/android-v0.7.2/Tacit-0.7.2.apk|0.8.0",
    );
  });

  test("文档站正确渲染 Markdown 并移除顶部注释和 GitHub 语言切换行", () => {
    const enTrial = readFileSync(join(distDir, "en/docs/trial-guide/index.html"), "utf8");
    expect(enTrial).not.toContain("<!-- source:");
    expect(enTrial).not.toContain("English | ");
    expect(enTrial).toContain('href="../troubleshooting/"');
    expect(enTrial).toContain("doc-toc");

    const zhServer = readFileSync(join(distDir, "zh/docs/server-deployment/index.html"), "utf8");
    expect(zhServer).toContain('id="7-windows-电脑docker-desktop"');
    expect(zhServer).toContain("doc-code-block");
    expect(zhServer).toContain("data-copy-code");
  });
});

describe("文档源目录双布局兼容", () => {
  test("旧布局：docs/<slug>.md 为中文，docs/en/<slug>.md 为英文", () => {
    const dir = mkdtempSync(join(tmpdir(), "tacit-docs-legacy-"));
    tempDirs.push(dir);
    mkdirSync(join(dir, "docs/en"), { recursive: true });
    writeFileSync(join(dir, "docs/trial-guide.md"), "# 试用说明\n");
    writeFileSync(join(dir, "docs/en/trial-guide.md"), "# Trying Tacit\n");

    expect(resolveDocSource(dir, "en", "trial-guide")).toBe("docs/en/trial-guide.md");
    expect(resolveDocSource(dir, "zh", "trial-guide")).toBe("docs/trial-guide.md");
  });

  test("新布局（英文优先）：docs/<slug>.md 为英文，docs/zh/<slug>.md 为中文", () => {
    const dir = mkdtempSync(join(tmpdir(), "tacit-docs-en-first-"));
    tempDirs.push(dir);
    mkdirSync(join(dir, "docs/zh"), { recursive: true });
    writeFileSync(join(dir, "docs/trial-guide.md"), "# Trying Tacit\n");
    writeFileSync(join(dir, "docs/zh/trial-guide.md"), "# 试用说明\n");

    expect(resolveDocSource(dir, "en", "trial-guide")).toBe("docs/trial-guide.md");
    expect(resolveDocSource(dir, "zh", "trial-guide")).toBe("docs/zh/trial-guide.md");
  });
});

describe("Markdown 清洗、链接重写与渲染辅助函数", () => {
  test("stripDocPreamble 去除 source 注释与 GitHub 语言切换行", () => {
    const input = [
      "<!-- source: docs/trial-guide.md @ abc123 -->",
      "",
      "English | [简体中文](../trial-guide.md)",
      "",
      "# Trying Tacit",
      "",
      "Body text.",
    ].join("\n");
    expect(stripDocPreamble(input)).toBe("# Trying Tacit\n\nBody text.");

    const zhInput = "[English](en/trial-guide.md)\n\n# 试用说明\n\n正文。";
    expect(stripDocPreamble(zhInput)).toBe("# 试用说明\n\n正文。");
  });

  test("rewriteDocHref 正确重写站内文档路由与仓库 GitHub 链接", () => {
    expect(rewriteDocHref("troubleshooting.md", "docs/en/trial-guide.md")).toBe("../troubleshooting/");
    expect(rewriteDocHref("troubleshooting.md#sync", "docs/trial-guide.md")).toBe("../troubleshooting/#sync");
    expect(rewriteDocHref("../contracts.md#2-插件协议", "docs/en/plugins.md")).toBe(
      "https://github.com/JinSooo/tacit/blob/main/docs/contracts.md#2-插件协议",
    );
    expect(rewriteDocHref("../../examples/text-file-plugin", "docs/en/plugins.md")).toBe(
      "https://github.com/JinSooo/tacit/blob/main/examples/text-file-plugin",
    );
    expect(rewriteDocHref("../../README.md", "docs/en/installation.md")).toBe(
      "https://github.com/JinSooo/tacit/blob/main/README.md",
    );
    expect(rewriteDocHref("#7-windows-with-docker-desktop", "docs/en/server-deployment.md")).toBe(
      "#7-windows-with-docker-desktop",
    );
    expect(rewriteDocHref("https://example.com/a", "docs/en/trial-guide.md")).toBe("https://example.com/a");
  });

  test("slugifyHeading 生成与 GitHub 兼容的中英文锚点", () => {
    expect(slugifyHeading("7. Windows 电脑（Docker Desktop）")).toBe("7-windows-电脑docker-desktop");
    expect(slugifyHeading("2. Get the image and start the container")).toBe("2-get-the-image-and-start-the-container");
  });

  test("renderDocMarkdown 渲染 Alert、表格包裹、代码块复制按钮且不改写代码块内文本", () => {
    const md = [
      "# Guide",
      "",
      "## Overview",
      "",
      "> [!WARNING]",
      "> Keep your key safe.",
      "",
      "| Col | Val |",
      "| --- | --- |",
      "| A | 1 |",
      "",
      "```html",
      '<a href="troubleshooting.md">keep literal</a>',
      "```",
    ].join("\n");

    const rendered = renderDocMarkdown(md, "docs/en/trial-guide.md", "en");
    expect(rendered.title).toBe("Guide");
    expect(rendered.toc).toEqual([{ level: 2, id: "overview", text: "Overview" }]);
    expect(rendered.html).toContain('class="doc-alert doc-alert-warning"');
    expect(rendered.html).toContain("Warning");
    expect(rendered.html).toContain('class="doc-table-wrap"');
    expect(rendered.html).toContain('class="doc-code-block"');
    expect(rendered.html).toContain("data-copy-code");
    expect(rendered.html).toContain("&lt;a href=&quot;troubleshooting.md&quot;&gt;keep literal&lt;/a&gt;");
  });

  test("renderDocMarkdown 清洗原始 HTML、阻断主动内容且不对查询参数双重转义", () => {
    const md = [
      "# Security",
      "",
      "Check [query link](https://example.com/?p=1&q=2) and [bad](javascript:alert(1)).",
      "",
      "<details open><summary>Note</summary>Safe text</details>",
      "",
      '<script>window.pwned = true</script><iframe src="https://evil.example"></iframe>',
      '<a href="&#106;avascript:alert(1)" onclick="alert(1)">encoded</a>',
      '<img src="data:image/svg+xml,<svg/>" onerror="alert(1)">',
    ].join("\n");

    const rendered = renderDocMarkdown(md, "docs/en/trial-guide.md", "en");
    expect(rendered.html).toContain('href="https://example.com/?p=1&amp;q=2"');
    expect(rendered.html).not.toContain("&amp;amp;");
    expect(rendered.html).not.toContain("<script");
    expect(rendered.html).not.toContain("window.pwned");
    expect(rendered.html).not.toContain("<iframe");
    expect(rendered.html).not.toContain("<details");
    expect(rendered.html).not.toContain("<summary");
    expect(rendered.html).toContain("Safe text");
    expect(rendered.html).not.toContain("onclick");
    expect(rendered.html).not.toContain("onerror");
    expect(rendered.html).not.toContain("javascript:");
    expect(rendered.html).not.toContain("data:image");

    expect(sanitizeDocHtml('<a href="https://example.com/?a=1&amp;b=2" style="color:red">ok</a>')).toBe(
      '<a href="https://example.com/?a=1&amp;b=2">ok</a>',
    );

    // 单遍 HTML 实体解码：命名实体大小写精确匹配、不命中原型属性、字面实体不二次解码、C1 与越界数字实体合规
    const entityMd = [
      "# Entities",
      "",
      '<a href="https://example.com/?currency=&euro;&amp;c1=&#128;&amp;acc=&eacute;&amp;literal=&amp;lt;&amp;unknown=&Euro;&amp;proto=&constructor;&amp;bad=&#99999999;">link</a>',
    ].join("\n");
    const entityRendered = renderDocMarkdown(entityMd, "docs/en/trial-guide.md", "en");
    expect(entityRendered.html).toContain(
      'href="https://example.com/?currency=€&amp;c1=€&amp;acc=é&amp;literal=&amp;lt;&amp;unknown=&amp;Euro;&amp;proto=&amp;constructor;&amp;bad=\ufffd"',
    );
    expect(entityRendered.html).not.toContain("function Object");
    expect(entityRendered.html).not.toContain("&amp;euro;");
    expect(entityRendered.html).not.toContain("literal=<");

    expect(() =>
      auditHtmlPage("en/docs/test/index.html", '<div class="doc-prose"><script>1</script></div>'),
    ).toThrow(/禁止的标签/);
    expect(() =>
      auditHtmlPage("en/docs/test/index.html", '<div class="doc-prose"><a href="javascript:alert(1)">x</a></div>'),
    ).toThrow(/不安全的链接协议/);
  });
});

describe("--serve 路由解析", () => {
  test("干净路径、尾斜杠重定向、静态文件与 404 处理", () => {
    expect(resolveServeTarget("/", "", distDir)).toEqual({ kind: "file", relPath: "index.html", isHtml: true });
    expect(resolveServeTarget("/en", "", distDir)).toEqual({ kind: "redirect", location: "/en/" });
    expect(resolveServeTarget("/en/", "", distDir)).toEqual({ kind: "file", relPath: "en/index.html", isHtml: true });
    expect(resolveServeTarget("/zh", "?ref=1", distDir)).toEqual({ kind: "redirect", location: "/zh/?ref=1" });
    expect(resolveServeTarget("/zh/", "", distDir)).toEqual({ kind: "file", relPath: "zh/index.html", isHtml: true });
    expect(resolveServeTarget("/en/download", "", distDir)).toEqual({ kind: "redirect", location: "/en/download/" });
    expect(resolveServeTarget("/en/download/", "", distDir)).toEqual({
      kind: "file",
      relPath: "en/download/index.html",
      isHtml: true,
    });
    expect(resolveServeTarget("/en/docs", "", distDir)).toEqual({ kind: "redirect", location: "/en/docs/" });
    expect(resolveServeTarget("/en/docs/troubleshooting", "", distDir)).toEqual({
      kind: "redirect",
      location: "/en/docs/troubleshooting/",
    });
    expect(resolveServeTarget("/en/docs/troubleshooting/", "", distDir)).toEqual({
      kind: "file",
      relPath: "en/docs/troubleshooting/index.html",
      isHtml: true,
    });
    expect(resolveServeTarget("/latest.json", "", distDir)).toEqual({
      kind: "file",
      relPath: "latest.json",
      isHtml: false,
    });
    expect(resolveServeTarget("/../package.json", "", distDir)).toEqual({ kind: "not-found" });
    expect(resolveServeTarget("/does-not-exist/", "", distDir)).toEqual({ kind: "not-found" });
  });
});
