// The email link pages (src/components/EmailLinkPage.astro): read the token from the `#` part, take it off the address
// bar at once (it stays out of history and bookmarks), and on the button's click send it to the API:
// `POST /v1/email/confirm` and `/v1/email/not-me` with `{token}`, `POST /v1/email/unsubscribe?s=<token>` (the same
// endpoint the RFC 8058 one-click uses). The token is never logged.
import { dataValue, element } from "./dom";
import { siteConfig } from "../site";

type EmailAction = "confirm" | "not-me" | "unsubscribe";

/** What became of the click. */
type Outcome = "done" | "invalid" | "rate_limited" | "failed";

function actionOf(value: string): EmailAction {
  if (value === "confirm" || value === "not-me" || value === "unsubscribe") {
    return value;
  }
  throw new Error(`Unknown email link action: ${value}`);
}

/** The request for the action. Pure function. */
function requestFor(action: EmailAction, token: string, apiBase: string): { readonly url: string; readonly init: RequestInit } {
  if (action === "unsubscribe") {
    return { url: `${apiBase}/v1/email/unsubscribe?s=${encodeURIComponent(token)}`, init: { method: "POST" } };
  }
  return {
    url: `${apiBase}/v1/email/${action}`,
    init: { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token }) },
  };
}

/** The outcome of the API's answer. Pure function. */
function outcomeOf(status: number): Outcome {
  if (status >= 200 && status < 300) {
    return "done";
  }
  if (status === 404 || status === 400) {
    return "invalid";
  }
  return status === 429 ? "rate_limited" : "failed";
}

async function send(action: EmailAction, token: string): Promise<Outcome> {
  const request = requestFor(action, token, siteConfig.apiBase);
  try {
    const response: Response = await fetch(request.url, { ...request.init, credentials: "omit", referrerPolicy: "no-referrer" });
    return outcomeOf(response.status);
  } catch (error: unknown) {
    // A network failure (offline, blocked): the page offers a retry; nothing else to recover.
    console.warn("email link request failed", error instanceof Error ? error.name : typeof error);
    return "failed";
  }
}

function start(): void {
  const page: HTMLElement = element("email-link", HTMLElement);
  const copy: HTMLTemplateElement = element("email-link-copy", HTMLTemplateElement);
  const title: HTMLElement = element("email-link-title", HTMLElement);
  const text: HTMLElement = element("email-link-text", HTMLElement);
  const button: HTMLButtonElement = element("email-link-button", HTMLButtonElement);
  const status: HTMLElement = element("email-link-status", HTMLElement);
  const action: EmailAction = actionOf(dataValue(page, "action"));
  const token: string = window.location.hash.slice(1);
  if (window.location.hash !== "") {
    history.replaceState(null, "", window.location.pathname);
  }
  const finish = (heading: string, message: string): void => {
    title.textContent = heading;
    text.textContent = message;
    button.classList.add("hidden");
    status.textContent = "";
  };
  if (!/^[A-Za-z0-9_.-]{20,}$/.test(token)) {
    finish(dataValue(copy, "incompleteTitle"), dataValue(copy, "incomplete"));
    return;
  }
  button.addEventListener("click", (): void => {
    button.disabled = true;
    status.textContent = dataValue(copy, "working");
    void send(action, token).then((outcome: Outcome): void => {
      button.disabled = false;
      switch (outcome) {
        case "done":
          finish(dataValue(copy, "doneTitle"), dataValue(copy, "done"));
          return;
        case "invalid":
          finish(dataValue(copy, "invalidTitle"), dataValue(copy, "invalid"));
          return;
        case "rate_limited":
          status.textContent = dataValue(copy, "rateLimited");
          button.textContent = dataValue(copy, "retry");
          return;
        case "failed":
          status.textContent = `${dataValue(copy, "failedTitle")} ${dataValue(copy, "failed")}`;
          button.textContent = dataValue(copy, "retry");
          return;
      }
    });
  });
}

start();
