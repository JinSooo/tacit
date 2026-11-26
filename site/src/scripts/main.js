const nav = document.getElementById("nav");

for (const langLink of document.querySelectorAll("[data-lang-switch]")) {
  langLink.addEventListener("click", () => {
    const nextLang = langLink.getAttribute("data-lang-switch");
    if (nextLang === "zh" || nextLang === "en") {
      try { localStorage.setItem("tacit-lang", nextLang); } catch {}
    }
  });
}

const navLinks = [...document.querySelectorAll(".nav-links a[href^='#']")];
const linkById = new Map(navLinks.map((link) => [link.getAttribute("href").slice(1), link]));
const allSections = [...document.querySelectorAll("main > section[id]")];

function updateNav() {
  if (!nav) return;
  nav.toggleAttribute("data-scrolled", window.scrollY > 8);
  if (!allSections.length || !navLinks.length) return;
  const probe = window.scrollY + nav.offsetHeight + window.innerHeight * 0.28;
  let activeId = null;
  for (const section of allSections) {
    if (section.offsetTop <= probe) activeId = section.id;
  }
  const activeLink = activeId ? linkById.get(activeId) ?? null : null;
  for (const link of navLinks) {
    if (link === activeLink) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  }
}

updateNav();
window.addEventListener("scroll", updateNav, { passive: true });
window.addEventListener("resize", updateNav, { passive: true });

// Docs right-hand TOC scrollspy
const tocLinks = [...document.querySelectorAll(".doc-toc a[href^='#']")];
const tocTargets = tocLinks
  .map((link) => ({ link, heading: document.getElementById(link.getAttribute("href").slice(1)) }))
  .filter((item) => item.heading);

function updateDocToc() {
  if (!tocTargets.length) return;
  const offset = (nav?.offsetHeight ?? 64) + 28;
  let active = tocTargets[0];
  for (const item of tocTargets) {
    if (item.heading.getBoundingClientRect().top <= offset) active = item;
  }
  for (const item of tocTargets) {
    if (item === active) item.link.setAttribute("aria-current", "location");
    else item.link.removeAttribute("aria-current");
  }
}

if (tocTargets.length) {
  updateDocToc();
  window.addEventListener("scroll", updateDocToc, { passive: true });
}

// Theme icon toggle
const toggle = document.getElementById("theme-toggle");
const darkQuery = matchMedia("(prefers-color-scheme: dark)");
const widgetPicture = document.querySelector(".more-widgets");
const widgetSource = widgetPicture?.querySelector("source");
const widgetImg = widgetPicture?.querySelector("img");
const lightWidget = widgetImg?.getAttribute("src");
const darkWidget = widgetSource?.getAttribute("srcset");

function syncThemeUi(theme) {
  if (!toggle) return;
  const isDark = theme === "dark" || (!theme && darkQuery.matches);
  const label = isDark ? toggle.dataset.lightLabel : toggle.dataset.darkLabel;
  toggle.dataset.activeTheme = isDark ? "dark" : "light";
  toggle.setAttribute("aria-label", label);
  toggle.setAttribute("title", label);
  if (widgetSource && widgetImg) {
    if (theme === "dark") {
      widgetSource.media = "all";
      widgetImg.src = darkWidget;
    } else if (theme === "light") {
      widgetSource.media = "not all";
      widgetImg.src = lightWidget;
    } else {
      widgetSource.media = "(prefers-color-scheme: dark)";
      widgetImg.src = lightWidget;
    }
  }
}

if (toggle) {
  let saved = null;
  try { saved = localStorage.getItem("tacit-theme"); } catch {}
  if (saved === "light" || saved === "dark") {
    document.documentElement.setAttribute("data-theme", saved);
  }
  syncThemeUi(document.documentElement.getAttribute("data-theme"));
  toggle.hidden = false;

  toggle.addEventListener("click", () => {
    const current = document.documentElement.getAttribute("data-theme");
    const isDark = current === "dark" || (!current && darkQuery.matches);
    const next = isDark ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("tacit-theme", next); } catch {}
    syncThemeUi(next);
  });

  darkQuery.addEventListener("change", () => {
    if (!document.documentElement.getAttribute("data-theme")) syncThemeUi(null);
  });
}

// Shared copy buttons (download page commands and docs code blocks)
if (navigator.clipboard?.writeText) {
  for (const button of document.querySelectorAll("[data-copy-target], [data-copy-code]")) {
    button.hidden = false;
    let resetTimer = null;
    const defaultLabel = button.textContent.trim();

    button.addEventListener("click", async () => {
      let text = "";
      const targetId = button.getAttribute("data-copy-target");
      if (targetId) {
        text = document.getElementById(targetId)?.textContent?.trim() ?? "";
      } else {
        const container = button.closest(".doc-code-block");
        text = container?.querySelector("pre code")?.textContent?.trim() ?? "";
      }
      if (!text) return;

      const statusId = button.getAttribute("data-copy-status-id");
      const statusEl = statusId
        ? document.getElementById(statusId)
        : button.closest(".doc-code-block")?.querySelector("[data-copy-status]");

      try {
        await navigator.clipboard.writeText(text);
        if (statusEl) statusEl.textContent = button.dataset.copied || defaultLabel;
        if (button.dataset.copiedButton) button.textContent = button.dataset.copiedButton;
        button.setAttribute("data-copied-state", "true");
        clearTimeout(resetTimer);
        resetTimer = setTimeout(() => {
          button.textContent = defaultLabel;
          button.removeAttribute("data-copied-state");
        }, 1800);
      } catch {
        if (statusEl) statusEl.textContent = button.dataset.copyFailed || "";
      }
    });
  }
}

// Scroll reveals
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const targets = document.querySelectorAll("[data-reveal], [data-reveal-group]");
if (reduced || !("IntersectionObserver" in window)) {
  targets.forEach((el) => el.classList.add("is-in"));
} else {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        e.target.classList.add("is-in");
        io.unobserve(e.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.05 },
  );
  targets.forEach((el) => io.observe(el));
}
