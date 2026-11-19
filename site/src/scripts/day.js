const switcher = document.querySelector("#day .day-switch");

if (switcher) {
  const views = [...switcher.querySelectorAll("button")].map(button => ({
    button,
    panel: document.getElementById(button.getAttribute("aria-controls")),
  }));

  function selectView(selected) {
    for (const view of views) {
      const active = view === selected;
      view.button.setAttribute("aria-pressed", String(active));
      view.panel.hidden = !active;
    }
  }

  for (const view of views) {
    view.button.addEventListener("click", () => selectView(view));
  }

  switcher.hidden = false;
}
