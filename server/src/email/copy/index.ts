import { de } from "./de";
import { en } from "./en";
import { es } from "./es";
import { fi } from "./fi";
import { fr } from "./fr";
import { it } from "./it";
import { ja } from "./ja";
import { ko } from "./ko";
import { nl } from "./nl";
import { ptBR } from "./ptBR";
import { tr } from "./tr";
import type { EmailCopy } from "./types";
import { zhHans } from "./zhHans";

/** Email languages: the apps' source (tr), English and `scripts/l10n.py` `TARGET_LANGUAGES`. */
export const emailLocales = ["en", "tr", "de", "fr", "es", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans", "fi"] as const;

export type EmailLocale = (typeof emailLocales)[number];

/** Every language's copy. */
export const emailCopies: Readonly<Record<EmailLocale, EmailCopy>> = {
  en,
  tr,
  de,
  fr,
  es,
  it,
  "pt-BR": ptBR,
  nl,
  ja,
  ko,
  "zh-Hans": zhHans,
  fi,
};

/**
 * The email language for the app's language tag (`Bundle.preferredLocalizations.first`, e.g. "de", "pt-BR", "zh-Hans",
 * "en-GB"): an exact match, else the language part ("pt" → "pt-BR", "zh" → "zh-Hans"), else English. Pure function.
 */
export function emailLocaleOf(tag: string): EmailLocale {
  const exact: EmailLocale | undefined = emailLocales.find((locale: EmailLocale): boolean => locale.toLowerCase() === tag.toLowerCase());
  if (exact !== undefined) {
    return exact;
  }
  const language: string = (tag.split(/[-_]/)[0] ?? "").toLowerCase();
  const byLanguage: EmailLocale | undefined = emailLocales.find((locale: EmailLocale): boolean => locale.split("-")[0]?.toLowerCase() === language);
  return byLanguage ?? "en";
}
