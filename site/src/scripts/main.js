// 公共脚本：导航滚动分隔线、进入视口淡入。区块脚本各自独立，不依赖这里。
const nav = document.getElementById("nav");
const onScroll = () => nav.toggleAttribute("data-scrolled", window.scrollY > 8);
onScroll();
window.addEventListener("scroll", onScroll, { passive: true });

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
