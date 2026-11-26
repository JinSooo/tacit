English | [简体中文](README.zh-CN.md)

# Tacit website

Bun builds the bilingual static site using its built-in APIs, including `Bun.markdown.html`. The build has no external dependencies.

```sh
bun site/build.ts           # Build into site/dist
bun site/build.ts --serve   # Preview at http://127.0.0.1:4300 (override with PORT). HTML requests trigger a rebuild.
bun test site/              # Run build, routing, and documentation link tests
```

## Routes

The build writes to `site/dist/`. Every page inlines shared styles, scripts, and source icons. Pages share the root `assets/` directory. The Mac app's update feed, `latest.json`, stays at the root.

| Route | Output | Description |
| --- | --- | --- |
| `/` | `index.html` | JavaScript reads the saved `tacit-lang` preference in `localStorage` or uses the browser language. Languages starting with `zh` go to `/zh/`, and all others go to `/en/`. The redirect keeps the query and fragment. With JavaScript disabled, a meta refresh goes to `/en/`. Configure a redirect at the hosting layer if you need to retain the query and fragment without JavaScript. |
| `/en/`, `/zh/` | `en/index.html`, `zh/index.html` | Product homepages. The hero and closing section show one primary download for the visitor's device and link to downloads for all platforms. |
| `/en/download/`, `/zh/download/` | `en/download/index.html`, `zh/download/index.html` | Download pages for Mac, Android, and the standalone Docker service, plus planned platforms. The Mac instructions include three first-launch steps and a command you can copy. |
| `/en/docs/`, `/zh/docs/` | `en/docs/index.html`, `zh/docs/index.html` | Documentation indexes. |
| `/en/docs/<slug>/`, `/zh/docs/<slug>/` | `en/docs/<slug>/index.html`, `zh/docs/<slug>/index.html` | Guides built from Markdown in `docs/` for trying Tacit, troubleshooting, server deployment, installation, and plugins. |
| `/latest.json` | `latest.json` | A copy of `site/src/latest.json` for the Mac app's daily update check. |

Each locale under `site/src/en/` and `site/src/zh/` has a homepage shell (`index.html`), sections (`sections/*.html`), a download page (`download.html`), and a shared fragment (`day-overview.html`). The build expands `<!-- include: path -->` directives. Paths are relative to the file containing the directive.

The build reads English guides from `docs/<slug>.md` and Chinese translations from `docs/zh/<slug>.md`. It can also read older checkouts that put Chinese guides at the root of `docs/` and English guides in the `en/` subdirectory. The pages load no external CDN resources or analytics scripts.

## Deployment

The live site at [tacit.jinso.top](https://tacit.jinso.top/) directs visitors to `/en/` (the default) or `/zh/`. Run `bun site/build.ts` and upload the entire `site/dist/` directory to a static host such as Cloudflare Pages, GitHub Pages, or your own Nginx server.

For manual deployment with `wrangler pages deploy`, copy `site/dist/` into a temporary directory outside the repository first. This keeps Wrangler from generating configuration files at the repository root.

## Homepage sections

| Order | ID | Content |
| --- | --- | --- |
| 1 | `hero` | Product introduction, one download button for the visitor's device, a link to all downloads, and a Timeline that continues as the day goes on |
| 2 | `day` | Simple and Detailed Timeline views, original records that open in place, and an example Project page |
| 3 | `ai` | Session context, AI tool searches, and links back to original records in a dark terminal window |
| 4 | `how` | How Tacit weighs sources by how directly they reflect your intent, summarizes locally, and makes results available to you and your AI tools |
| 5 | `more` | Search, meetings and chats, and desktop widgets |
| 6 | `privacy` | What data stays on your device and what can leave it |
| 7 | `faq` | Common questions |
| 8 | `download` | One download button for the visitor's device, plus links to the download page and documentation |

## Visual direction

The site looks like a sheet of paper that keeps filling in as the day goes on. The app icon sets the direction. A thin vertical line connects three activity bars of decreasing length, and the copper-green dot marks the activity in progress.

- Use `--paper`, a subtle alternating `--band`, and thin rules to divide sections. On desktop, center each homepage section within the viewport. On mobile, let sections flow. Reserve the copper-green `--accent` for links, the current location, activity bars, and occasional emphasis.
- The terminal in the `ai` section uses `.band-night`, the same warm charcoal as the icon. The rest of the section and the documentation code blocks stay on the paper background.
- Use serif type for narrative headings, the Day overview, Task titles, and document titles (`.display`, `.heading`, and `.title`). Use sans serif for body copy, buttons, and interface lists. Set commands, paths, and code in monospace.
- Build the Timeline, Project, terminal, and widget examples in HTML. That keeps text selectable and readable in either theme. The `more` section can also use the existing `assets/widget-*.png` images.
- Use the 24 × 24 monochrome symbols from `assets/sources.svg` with a 1.6 px stroke and `currentColor`. The header uses `lang` for language and `sun` / `moon` for theme.
- Use whitespace or a thin `--line` for separation. Avoid shadows, glows, background gradients, frosted glass, and nested cards.
- Fade in elements marked `data-reveal` as they enter the viewport. Show their final state immediately under `prefers-reduced-motion: reduce`.
- Use the six type sizes in `base.css` and at most four in one section. Avoid italics, all caps, and letter spacing. Wrap times and numbers in `.num` for tabular digits.

## Copy

- Use short sentences in both languages. Say what Tacit does and how it works. Use sentence case in English and give Latin serif fonts priority in narrative headings and the Day overview.
- Follow the English UI terms in [section 1 of the UI specification](../docs/ui.md), including Task, Summarize, Session context, AI tools, Timeline, Activity, and Based on. Keep internal implementation terms out of interface copy.
- State the supported platforms accurately. Tacit runs on Apple silicon Macs with macOS 14 or later and arm64 Android phones with Android 9 or later. A cloud Summary model receives the text it needs. Tacit collects no telemetry. A Windows client is planned, Intel Macs are unsupported, and iOS is under exploration.
- The build fills and validates version and download placeholders on the homepages and download pages. It reads Mac from `site/src/latest.json`, Android from `android/app/build.gradle.kts`, and the Docker service from `package.json`. Update the relevant version source at release time and run `bun site/build.ts`.

## Verification

- Run `bun site/build.ts`. Verify that the locales have matching routes, unique IDs, and no unexpanded includes. The Mac download links must match `latest.json`, and all internal links and anchors must resolve.
- Run `bun test site/ scripts/release-version.test.ts`.
- Run `PORT=4312 bun site/build.ts --serve` and check `/`, `/en`, `/en/`, `/zh`, `/zh/`, `/en/download`, `/zh/download/`, `/en/docs/`, `/zh/docs/troubleshooting/`, and `/latest.json`. Reload to confirm that the preview rebuilds.
- Check light and dark mode at widths of 1440, 1024, and 390 px. Look for horizontal scrolling, clipping, and overlap. At 390 px, check that the header and documentation navigation can collapse and expand.
- Use the keyboard to reach every interactive element and check that focus is visible. Decorative graphics use `aria-hidden="true"`. All content should be readable immediately with `prefers-reduced-motion: reduce`.
