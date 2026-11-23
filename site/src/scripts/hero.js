const preview = document.querySelector(".hero-window");
const motion = matchMedia("(prefers-reduced-motion: no-preference)");

if (preview && motion.matches) {
  preview.setAttribute("data-writing", "");

  const finish = () => {
    clearTimeout(timer);
    preview.removeAttribute("data-writing");
    motion.removeEventListener("change", finish);
    window.removeEventListener("pagehide", finish);
  };

  const timer = setTimeout(finish, 720);
  motion.addEventListener("change", finish, { once: true });
  window.addEventListener("pagehide", finish, { once: true });
}
