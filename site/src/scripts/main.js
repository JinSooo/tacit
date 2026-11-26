// Prioritize the current platform without hiding the other download.
if (document.documentElement.getAttribute("data-platform") === "android") {
  for (const group of document.querySelectorAll("[data-platform-actions]")) {
    const mac = group.querySelector('[data-platform-target="mac"]');
    const android = group.querySelector('[data-platform-target="android"]');
    if (mac && android) {
      group.insertBefore(android, mac);
      android.classList.replace("btn-quiet", "btn-primary");
      mac.classList.replace("btn-primary", "btn-quiet");
    }
  }
  const guide = document.querySelector(".download-guide");
  const macGuide = guide?.querySelector(".download-mac");
  const androidGuide = guide?.querySelector(".download-android");
  if (guide && macGuide && androidGuide) {
    guide.insertBefore(androidGuide, macGuide);
  }
}

const nav = document.getElementById("nav");
const languageNotice = document.getElementById("language-notice");
const pageLanguage = document.documentElement.lang.toLowerCase().split("-")[0];
const preferredLanguages = navigator.languages?.length ? navigator.languages : [navigator.language].filter(Boolean);
const noticeKey = `tacit-language-notice-${pageLanguage}`;
let noticeDismissed = false;
try { noticeDismissed = localStorage.getItem(noticeKey) === "dismissed"; } catch {}
if (preferredLanguages.length && !noticeDismissed && !preferredLanguages.some(
  (language) => language.toLowerCase().split("-")[0] === pageLanguage,
)) {
  languageNotice.hidden = false;
  languageNotice.querySelector("button").addEventListener("click", () => {
    languageNotice.hidden = true;
    try { localStorage.setItem(noticeKey, "dismissed"); } catch {}
    nav.querySelector(".nav-language").focus();
    updateNav();
  });
}

const navLinks = [...document.querySelectorAll(".nav-links a[href^='#']")];
const linkById = new Map(navLinks.map((link) => [link.getAttribute("href").slice(1), link]));
const allSections = [...document.querySelectorAll("main > section[id]")];

function updateNav() {
  nav.toggleAttribute("data-scrolled", window.scrollY > 8);
  if (!allSections.length) return;
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
  toggle.textContent = isDark ? toggle.dataset.light : toggle.dataset.dark;
  toggle.setAttribute("aria-label", isDark ? toggle.dataset.lightLabel : toggle.dataset.darkLabel);
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
