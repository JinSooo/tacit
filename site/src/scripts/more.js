const form = document.querySelector(".more-search-form");

if (form) {
  const { query, day, source, device } = form.elements;
  const group = document.querySelector(".more-search-day");
  const empty = document.querySelector(".more-search-empty");
  const records = Array.from(group.querySelectorAll("li"), (row) => ({
    row,
    fields: Array.from(row.querySelectorAll("[data-search-text]"), (element) => ({
      element,
      text: element.textContent,
    })),
  }));

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
  }

  form.addEventListener("submit", (event) => event.preventDefault());
  form.addEventListener("input", updateResults);
  query.readOnly = false;
  for (const select of [day, source, device]) select.disabled = false;
}
