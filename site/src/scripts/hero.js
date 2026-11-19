const preview = document.querySelector(".hero-window");
const motion = matchMedia("(prefers-reduced-motion: no-preference)");

if (preview && motion.matches) {
  const summary = preview.querySelector("[data-hero-summary]");
  const rows = [...preview.querySelectorAll(".hero-timeline li")];
  const line = preview.querySelector(".hero-writing-line");
  const letters = Array.from(summary.textContent);
  const writing = document.createElement("span");
  const summaryDuration = 1240;
  const rowInterval = 250;
  const lineDelay = summaryDuration + rowInterval * rows.length;

  // Keep a complete sentence available to assistive technology throughout the sequence.
  writing.setAttribute("aria-hidden", "true");
  writing.replaceChildren(...letters.map((letter, index) => {
    const glyph = document.createElement("span");
    glyph.className = "hero-glyph";
    glyph.textContent = letter;
    glyph.style.setProperty("--hero-letter-delay", `${index * summaryDuration / letters.length}ms`);
    return glyph;
  }));

  rows.forEach((row, index) => {
    row.style.setProperty("--hero-row-delay", `${summaryDuration + index * rowInterval}ms`);
  });
  line.style.setProperty("--hero-line-delay", `${lineDelay}ms`);

  summary.classList.add("visually-hidden");
  summary.after(writing);
  preview.setAttribute("data-writing", "");

  // Restore plain, selectable text after the one-shot animation.
  const finish = () => {
    clearTimeout(timer);
    preview.removeAttribute("data-writing");
    writing.remove();
    summary.classList.remove("visually-hidden");
    motion.removeEventListener("change", finish);
    window.removeEventListener("pagehide", finish);
  };

  const timer = setTimeout(finish, lineDelay + 280);
  motion.addEventListener("change", finish, { once: true });
  window.addEventListener("pagehide", finish, { once: true });
}
