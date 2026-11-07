// Copy buttons on code samples (CodeBlock.astro): copies the sample's text to the clipboard and shows "Copied" for two
// seconds, or that copying failed (the clipboard can be blocked, e.g. outside a secure context); the failure is logged
// with its reason. The button's texts come from its data attributes (copy.ts `mcp.copyButton`).

/** How long the result stays on the button (milliseconds). */
const resultMs: number = 2000;

/** Shows the result on the button and puts the label back after `resultMs`. */
function showResult(button: HTMLButtonElement, state: "copied" | "failed"): void {
  const text: HTMLElement | null = button.querySelector<HTMLElement>(".code-block__copy-text");
  if (text === null) {
    throw new Error("copy-code: the button has no .code-block__copy-text");
  }
  button.dataset["state"] = state;
  text.textContent = (state === "copied" ? button.dataset["copied"] : button.dataset["failed"]) ?? "";
  window.setTimeout(() => {
    delete button.dataset["state"];
    text.textContent = button.dataset["label"] ?? "";
  }, resultMs);
}

/** Copies the code of the block the button belongs to. */
async function copyCode(button: HTMLButtonElement): Promise<void> {
  const source: HTMLElement | null | undefined = button.closest(".code-block")?.querySelector<HTMLElement>("[data-copy-source]");
  if (source === null || source === undefined) {
    throw new Error("copy-code: the button's block has no [data-copy-source]");
  }
  try {
    await navigator.clipboard.writeText(source.textContent ?? "");
    showResult(button, "copied");
  } catch (error: unknown) {
    console.error("copy_code_failed", { error: error instanceof Error ? error.message : String(error) });
    showResult(button, "failed");
  }
}

for (const button of document.querySelectorAll<HTMLButtonElement>("button[data-copy-code]")) {
  button.addEventListener("click", () => {
    void copyCode(button);
  });
}
