/**
 * The words of every email in one language (`copy/<language>.ts`). Product names (Gistsmith, Gistsmith Keyboard,
 * Personal, Pro) and the app's labels follow the app's own translations (`App/Localizable.xcstrings`). Numbers come
 * from the configuration, never from the copy.
 */

/** The trial's terms (`TRIAL_MEETINGS`, `TRIAL_DAYS`). */
export interface TrialFacts {
  readonly meetings: number;
  readonly days: number;
}

/** What the free plan includes (`FREE_PLAN`). */
export interface FreePlanFacts {
  readonly notesPerMonth: number;
  readonly maxMeetingMinutes: number;
  readonly asksPerMonth: number;
}

/** The parts every email has: subject, the inbox preview line, the heading and the button. */
export interface EmailFrame {
  readonly subject: string;
  readonly preheader: string;
  readonly heading: string;
  readonly cta: string;
}

/** One language's copy. */
export interface EmailCopy {
  /** BCP 47 tag for `<html lang>`. */
  readonly htmlLang: string;
  readonly footer: {
    /** Why the reader gets a lifecycle email. */
    readonly lifecycleReason: string;
    /** The unsubscribe link's text. */
    readonly unsubscribe: string;
    /** Follows the unsubscribe link: the app's own switch. */
    readonly inApp: string;
    /** Why the reader gets the confirmation email, and that ignoring it is enough. */
    readonly confirmReason: string;
    /** The "This wasn't me" link's text (confirmation email). */
    readonly notMe: string;
    readonly privacy: (address: string) => string;
    /** The privacy policy link's text (the full legal details live there). */
    readonly privacyPolicy: string;
    /** "Finland" in this language: the footer's identity line is "Gistsmith · Oulu, <country>". */
    readonly country: string;
    readonly reply: string;
    /** Above the plain link under the button. */
    readonly linkFallback: string;
  };
  readonly confirm: EmailFrame & { readonly body: readonly string[]; readonly note: string };
  readonly welcome: EmailFrame & { readonly body: readonly string[] };
  readonly activation: EmailFrame & { readonly body: (trial: TrialFacts) => readonly string[] };
  readonly trialEnding: EmailFrame & {
    readonly oneMeetingLeft: string;
    readonly endsWithinDay: string;
    readonly nextFree: (free: FreePlanFacts) => string;
    readonly nextSubscribe: string;
    /** Closes both variants: the user's meetings and notes stay. */
    readonly keep: string;
  };
  readonly freePlan: EmailFrame & {
    readonly intro: string;
    readonly items: (free: FreePlanFacts) => readonly string[];
    readonly outro: string;
  };
}
