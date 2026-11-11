// İletişim formu: e-posta, mesaj (en çok 5000 karakter) ve Turnstile; `POST /v1/reports` `{kind: "contact", …}` → 202.
// Turnstile parçacığı sayfa temasıyla çizilir; tema değişince (henüz çözülmemişse de) yeniden çizilir.
import { send } from "./api";
import { type ClientCopy, clientCopy, fill } from "./copy";
import { ScriptLoadError, type Theme, currentTheme, element, errorText, hideNotice, loadScript, onThemeChange, showNotice } from "./dom";
import { turnstileScriptUrl } from "../config";
import { type ContactEffect, type ContactEvent, type ContactState, type ContactTransition, canSubmit, contactTransition, initialContact } from "../lib/contact-state";
import { siteConfig } from "../site";

/** Mesajın en uzun hâli (sunucunun sınırıyla aynı). */
const maxMessageLength: number = 5000;

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  const text: ClientCopy = clientCopy;
  const form: HTMLFormElement = element("contact-form", HTMLFormElement);
  const email: HTMLInputElement = element("contact-email", HTMLInputElement);
  const message: HTMLTextAreaElement = element("contact-message", HTMLTextAreaElement);
  const counter: HTMLElement = element("contact-counter", HTMLElement);
  const submit: HTMLButtonElement = element("contact-submit", HTMLButtonElement);
  const notice: HTMLElement = element("contact-error", HTMLElement);
  const sent: HTMLElement = element("contact-sent", HTMLElement);
  const again: HTMLButtonElement = element("contact-again", HTMLButtonElement);
  const container: HTMLElement = element("turnstile", HTMLElement);
  const submitLabel: string = submit.textContent;

  const updateCounter = (): void => {
    counter.textContent = fill(text.characters, { count: message.value.length.toLocaleString("en-GB"), max: maxMessageLength.toLocaleString("en-GB") });
  };
  message.addEventListener("input", updateCounter);
  updateCounter();

  await loadScript(turnstileScriptUrl);
  const turnstile: TurnstileGlobal | undefined = window.turnstile;
  if (turnstile === undefined) {
    throw new ScriptLoadError("window.turnstile tanımsız.");
  }
  const widget: { id: string } = { id: "" };
  const contact: { state: ContactState } = { state: initialContact };
  // Applies an event; the submit button follows the state. Returns the transition's effects for the caller to run.
  const apply = (event: ContactEvent): ContactTransition => {
    const transition: ContactTransition = contactTransition(contact.state, event);
    contact.state = transition.state;
    submit.disabled = !canSubmit(transition.state);
    return transition;
  };
  const renderWidget = (theme: Theme): string =>
    turnstile.render(container, {
      sitekey: siteConfig.turnstileSiteKey,
      action: "contact",
      theme,
      language: "en",
      size: "flexible",
      callback: (token: string): void => {
        apply({ kind: "tokenIssued", token });
      },
      "expired-callback": (): void => {
        apply({ kind: "tokenLost" });
      },
      "error-callback": (code: string): void => {
        apply({ kind: "tokenLost" });
        showNotice(notice, text.errors.turnstile);
        console.error("turnstile_failed", { code });
      },
    });
  widget.id = renderWidget(currentTheme());
  onThemeChange((theme: Theme): void => {
    turnstile.remove(widget.id);
    apply({ kind: "tokenLost" });
    widget.id = renderWidget(theme);
  });

  form.addEventListener("submit", (event: SubmitEvent): void => {
    event.preventDefault();
    if (!canSubmit(contact.state) || !form.reportValidity()) {
      return;
    }
    if (message.value.length > maxMessageLength) {
      showNotice(notice, text.errors.messageTooLong);
      return;
    }
    const sending: ContactTransition = apply({ kind: "submitRequested" });
    const effect: ContactEffect | undefined = sending.effects[0];
    if (effect?.kind !== "send") {
      return;
    }
    hideNotice(notice);
    submit.textContent = text.working;
    const turnstileToken: string = effect.token;
    void send({
      method: "POST",
      path: "/v1/reports",
      body: { kind: "contact", email: email.value.trim(), message: message.value.trim(), turnstileToken },
      accessToken: null,
      attempts: 1,
    })
      .then((): void => {
        form.classList.add("hidden");
        sent.classList.remove("hidden");
        sent.focus();
        form.reset();
        updateCounter();
      })
      .catch((error: unknown): void => {
        showNotice(notice, errorText(error, text));
      })
      .finally((): void => {
        // Turnstile yanıtı tek kullanımlıktır: her gönderimden sonra yenilenir. Tokens issued before the reset are
        // dropped; the button waits for the reset widget's new token.
        submit.textContent = submitLabel;
        if (apply({ kind: "submitFinished" }).effects.some((next: ContactEffect): boolean => next.kind === "resetWidget")) {
          turnstile.reset(widget.id);
        }
      });
  });

  again.addEventListener("click", (): void => {
    sent.classList.add("hidden");
    form.classList.remove("hidden");
    email.focus();
  });
}

main().catch((error: unknown): void => {
  showNotice(element("contact-error", HTMLElement), errorText(error, clientCopy));
});
