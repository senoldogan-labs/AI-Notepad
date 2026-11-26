import type { EmailConfig } from "../config";
import { log } from "../log";
import type { Platform } from "../platform";
import type { ComposedEmail, EmailKind } from "./messages";
import { type EmailCapRefusal, type EmailClass, takeEmailUnit } from "./quota";

/**
 * The only place that calls Cloudflare Email Service (`env.EMAIL.send`). Each attempt first takes a unit of the hard cap
 * (`quota.ts`). Errors carry a string `code` (Email Service docs › Workers API); they map to explicit outcomes:
 * - `undeliverable`: the recipient can't get mail from us (`E_RECIPIENT_SUPPRESSED` after a bounce or complaint,
 *   `E_VALIDATION_ERROR`, `E_DELIVERY_FAILED`); the caller deletes the address.
 * - `failed`: the service is busy (`E_RATE_LIMIT_EXCEEDED`, `E_INTERNAL_SERVER_ERROR`) after `sendAttempts` tries with
 *   backoff, a warning per retry; the caller tries again in a later run.
 * - `halted`: sending can't work now (`E_DAILY_LIMIT_EXCEEDED`, `E_SENDER_*`, `E_EMAIL_SENDING_NOT_READY`,
 *   `E_ACCOUNT_SUSPENDED`, a header or size error, anything else with a code); logged as `alert`, the caller stops.
 * - `cap`: our own cap refused the unit; nothing was handed over.
 * An error without a string `code` is a bug on our side and is thrown as it is. Logs never carry the address.
 */

/** Attempts per email for a busy service. */
export const sendAttempts: number = 3;

/** What became of one email. */
export type DeliveryOutcome =
  | { readonly kind: "sent"; readonly messageId: string }
  | { readonly kind: "cap"; readonly cap: EmailCapRefusal }
  | { readonly kind: "undeliverable"; readonly code: string }
  | { readonly kind: "failed"; readonly code: string }
  | { readonly kind: "halted"; readonly code: string };

const undeliverableCodes: ReadonlySet<string> = new Set(["E_RECIPIENT_SUPPRESSED", "E_VALIDATION_ERROR", "E_DELIVERY_FAILED"]);
const retryableCodes: ReadonlySet<string> = new Set(["E_RATE_LIMIT_EXCEEDED", "E_INTERNAL_SERVER_ERROR"]);

/** The Email Service error code of a thrown value; null when it has none. Pure function. */
export function emailErrorCode(error: unknown): string | null {
  if (error instanceof Error && "code" in error && typeof error.code === "string") {
    return error.code;
  }
  return null;
}

/** Sends one email to `to` within the caps. */
export async function deliverEmail(
  db: D1Database,
  sender: SendEmail,
  config: EmailConfig,
  platform: Pick<Platform, "retryBaseDelayMs" | "recordRetry">,
  to: string,
  kind: EmailKind,
  message: ComposedEmail,
  now: Date,
): Promise<DeliveryOutcome> {
  const emailClass: EmailClass = kind === "confirm" ? "confirm" : "lifecycle";
  for (let attempt: number = 1; ; attempt += 1) {
    const refusal: EmailCapRefusal | null = await takeEmailUnit(db, config, emailClass, now);
    if (refusal !== null) {
      return { kind: "cap", cap: refusal };
    }
    try {
      const result: EmailSendResult = await sender.send({
        from: { name: config.fromName, email: config.from },
        to,
        replyTo: config.replyTo,
        subject: message.subject,
        html: message.html,
        text: message.text,
        headers: { ...message.headers },
      });
      log("info", "email_sent", { kind, attempt });
      return { kind: "sent", messageId: result.messageId };
    } catch (error: unknown) {
      const code: string | null = emailErrorCode(error);
      if (code === null) {
        throw error;
      }
      if (undeliverableCodes.has(code)) {
        log("info", "email_undeliverable", { kind, code });
        return { kind: "undeliverable", code };
      }
      if (!retryableCodes.has(code)) {
        log("alert", "email_sending_halted", { kind, code });
        return { kind: "halted", code };
      }
      if (attempt >= sendAttempts) {
        log("error", "email_send_failed", { kind, code, attempts: attempt });
        return { kind: "failed", code };
      }
      log("warn", "upstream_retry", { service: "email", attempt, error: code });
      await platform.recordRetry("email");
      const delay: number = platform.retryBaseDelayMs * 2 ** (attempt - 1);
      if (delay > 0) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, delay);
        });
      }
    }
  }
}
