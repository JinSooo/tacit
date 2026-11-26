import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  build,
  DOCS,
  renderDocMarkdown,
  resolveDocSource,
  resolveServeTarget,
  rewriteDocHref,
  slugifyHeading,
  stripDocPreamble,
} from "./build.ts";

const siteDir = import.meta.dir;
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

  test("根路径 index.html 实现默认英文语言分流与无 JS 回落", () => {
    const rootHtml = readFileSync(join(distDir, "index.html"), "utf8");
    expect(rootHtml).toContain('localStorage.getItem("tacit-lang")');
    expect(rootHtml).toContain("navigator.languages");
    expect(rootHtml).toContain('primary.startsWith("zh")');
    expect(rootHtml).toContain("location.replace(");
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

  test("独立下载页包含 Mac、Android、Docker 与计划平台说明", () => {
    for (const locale of ["en", "zh"] as const) {
      const html = readFileSync(join(distDir, `${locale}/download/index.html`), "utf8");
      expect(html).toContain("https://github.com/JinSooo/tacit/releases/tag/mac-v0.7.0");
      expect(html).toContain("https://github.com/JinSooo/tacit/releases/tag/android-v0.7.0");
      expect(html).toContain("xattr -dr com.apple.quarantine /Applications/Tacit.app");
      expect(html).toContain("ghcr.io/jinsooo/tacit-hub");
      expect(html).toContain('href="../docs/server-deployment/"');
      expect(html).toContain('href="https://github.com/JinSooo/tacit/releases"');
      expect(html).toContain('aria-current="page"');
    }
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
