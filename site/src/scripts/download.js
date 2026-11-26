const button = document.querySelector(".download-copy");
const command = document.querySelector("#download-command");
const status = document.querySelector(".download-copy-status");

if (navigator.clipboard?.writeText) {
  button.hidden = false;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(command.textContent.trim());
      status.textContent = button.dataset.copied;
    } catch {
      status.textContent = button.dataset.copyFailed;
    }
  });
}
