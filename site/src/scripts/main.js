// 公共脚本：导航滚动分隔线、主题切换、进入视口淡入。区块脚本各自独立，不依赖这里。
const nav = document.getElementById("nav");
const onScroll = () => nav.toggleAttribute("data-scrolled", window.scrollY > 8);
onScroll();
window.addEventListener("scroll", onScroll, { passive: true });

const toggle = document.getElementById("theme-toggle");
const darkQuery = matchMedia("(prefers-color-scheme: dark)");
const widgetPicture = document.querySelector(".more-widgets");
const widgetSource = widgetPicture?.querySelector("source");
const widgetImg = widgetPicture?.querySelector("img");

function syncThemeUi(theme) {
  if (!toggle) return;
  const isDark = theme === "dark" || (!theme && darkQuery.matches);
  toggle.textContent = isDark ? "浅色" : "深色";
  toggle.setAttribute("aria-label", isDark ? "切换到浅色外观" : "切换到深色外观");
  if (widgetSource && widgetImg) {
    if (theme === "dark") {
      widgetSource.media = "all";
      widgetImg.src = "assets/widget-dark.png";
    } else if (theme === "light") {
      widgetSource.media = "not all";
      widgetImg.src = "assets/widget-light.png";
    } else {
      widgetSource.media = "(prefers-color-scheme: dark)";
      widgetImg.src = "assets/widget-light.png";
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
const targets = document.querySelectorAll("[data-reveal]");
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
    { rootMargin: "0px 0px -10% 0px" },
  );
  targets.forEach((el) => io.observe(el));
}
