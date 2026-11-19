const terminal = document.querySelector("#ai .ai-terminal");
const context = terminal?.querySelector(".ai-context");

if (context && "IntersectionObserver" in window && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
  const observer = new IntersectionObserver(([entry]) => {
    if (!entry.isIntersecting) return;
    observer.disconnect();
    terminal.setAttribute("data-written", "");
  }, { threshold: 0.25 });

  observer.observe(context);
}
