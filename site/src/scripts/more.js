const form = document.querySelector(".more-search-form");

if (form) {
  const { query, day, source, device } = form.elements;
  const chipsWrap = form.querySelector(".more-search-chips");
  const chips = chipsWrap ? [...chipsWrap.querySelectorAll("button[data-chip]")] : [];
  const group = document.querySelector(".more-search-day");
  const empty = document.querySelector(".more-search-empty");
  const records = Array.from(group.querySelectorAll("li"), (row) => ({
    row,
    fields: Array.from(row.querySelectorAll("[data-search-text]"), (element) => ({
      element,
      text: element.textContent,
    })),
  }));

  function syncChips() {
    const val = query.value.trim().toLowerCase();
    for (const chip of chips) {
      const target = chip.dataset.chip.trim().toLowerCase();
      chip.setAttribute("aria-pressed", String(val === target && !source.value));
    }
  }

  function updateResults() {
    const terms = query.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const pattern = terms.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
    const highlight = pattern ? new RegExp(`(${pattern})`, "gi") : null;
    let count = 0;

    for (const { row, fields } of records) {
      const text = fields.map((field) => field.text.toLowerCase()).join(" ");
      const matchesFilters = (!day.value || day.value === group.dataset.day)
        && (!source.value || source.value === row.dataset.source)
        && (!device.value || device.value === row.dataset.device);
      row.hidden = !matchesFilters || !terms.every((term) => text.includes(term));
      if (row.hidden) continue;

      count += 1;
      for (const { element, text: original } of fields) {
        if (!highlight) {
          element.textContent = original;
          continue;
        }

        const parts = original.split(highlight).map((part, index) => {
          if (index % 2 === 0) return part;
          const mark = document.createElement("mark");
          mark.textContent = part;
          return mark;
        });
        element.replaceChildren(...parts);
      }
    }

    group.hidden = count === 0;
    empty.hidden = count > 0;
    syncChips();
  }

  form.addEventListener("submit", (event) => event.preventDefault());
  form.addEventListener("input", updateResults);
  for (const chip of chips) {
    chip.addEventListener("click", () => {
      query.value = chip.dataset.chip;
      source.value = "";
      updateResults();
    });
  }
  query.readOnly = false;
  for (const select of [day, source, device]) select.disabled = false;
  if (chipsWrap) chipsWrap.hidden = false;
  updateResults();
}
