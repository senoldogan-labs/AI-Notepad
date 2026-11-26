import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const de: EmailCopy = {
  htmlLang: "de",
  footer: {
    lifecycleReason: "Du erhältst diese E-Mail, weil du Tipps und Erinnerungen von Gistsmith angefordert hast.",
    unsubscribe: "Abmelden",
    inApp: "oder schalte es in Gistsmith › Einstellungen › Account aus.",
    confirmReason:
      "Jemand hat diese Adresse in Gistsmith eingegeben. Warst du es nicht, ignoriere diese E-Mail einfach: Ohne Klick auf den Link senden wir nichts weiter, und wir löschen die Adresse innerhalb von 7 Tagen.",
    notMe: "Das war ich nicht",
    privacy: (address: string): string => `Fragen zum Datenschutz: ${address}`,
    privacyPolicy: "Datenschutzerklärung",
    country: "Finnland",
    reply: "Fragen? Antworte einfach auf diese E-Mail.",
    linkFallback: "Falls die Schaltfläche nicht funktioniert, öffne diesen Link:",
  },
  confirm: {
    subject: "Bestätige deine E-Mail-Adresse für Gistsmith",
    preheader: "Ein Klick, und du bekommst Tipps und deine Erinnerung zum Testzeitraum.",
    heading: "Bestätige deine E-Mail-Adresse",
    body: [
      "Du möchtest von Gistsmith ein paar Tipps und eine Erinnerung bekommen, bevor dein kostenloser Testzeitraum endet.",
      "Bestätige diese Adresse, dann geht es los. Wir senden nichts anderes, und du kannst jederzeit aufhören.",
    ],
    cta: "E-Mail-Adresse bestätigen",
    note: "Der Link ist 7 Tage gültig.",
  },
  welcome: {
    subject: "Dein erstes Meeting mit Gistsmith",
    preheader: "Nimm ein Meeting auf und erhalte die Notiz, sobald es endet.",
    heading: "Willkommen bei Gistsmith",
    body: [
      "Am schnellsten siehst du, was Gistsmith kann, mit einem echten Meeting. Wenn dein nächster Call beginnt, klicke auf dem Mac in Gistsmith auf Aufnahme starten oder öffne Gistsmith auf dem iPhone und tippe auf Aufnahme starten.",
      "Wenn das Meeting endet, bekommst du das Transkript, eine kurze Notiz und die Aufgaben.",
      "Auf dem iPhone kannst du mit der Gistsmith-Tastatur in jeder App per Sprache schreiben. Sie ist kostenlos: Schalte sie in Gistsmith › Einstellungen › Tastatur ein.",
    ],
    cta: "Meeting aufnehmen",
  },
  activation: {
    subject: "Bereit für dein erstes Meeting?",
    preheader: "Dein Testzeitraum beginnt erst mit deinem ersten Meeting.",
    heading: "Dein Testzeitraum hat noch nicht begonnen",
    body: (trial: TrialFacts): readonly string[] => [
      `Du hast dich bei Gistsmith angemeldet, aber noch kein Meeting aufgenommen. Kein Problem: Dein kostenloser Testzeitraum (${trial.meetings} Meetings oder ${trial.days} Tage) beginnt erst mit deinem ersten Meeting.`,
      "Starte beim nächsten Zoom-, Teams- oder Google-Meet-Call oder Meeting vor Ort die Aufnahme in Gistsmith. Die Notiz ist fertig, wenn das Meeting endet.",
      "Das ist die einzige Erinnerung, die wir dazu senden.",
    ],
    cta: "Meeting aufnehmen",
  },
  trialEnding: {
    subject: "Dein Gistsmith-Testzeitraum endet bald",
    preheader: "Was danach mit deinen Meetings und Notizen passiert.",
    heading: "Dein Testzeitraum endet bald",
    oneMeetingLeft: "Du hast noch ein kostenloses Test-Meeting.",
    endsWithinDay: "Dein kostenloser Testzeitraum endet innerhalb eines Tages.",
    nextFree: (free: FreePlanFacts): string =>
      `Danach wechselt dein Account automatisch in den Free-Plan: ${free.notesPerMonth} KI-Notizen pro Monat für Meetings bis ${free.maxMeetingMinutes} Minuten und ${free.asksPerMonth} Antworten von Fragen pro Monat.`,
    nextSubscribe: "Danach brauchst du ein Abo, damit Gistsmith deine Meetings weiter transkribiert und Notizen schreibt.",
    keep: "Deine Meetings und Notizen bleiben in jedem Fall auf deinen Geräten.",
    cta: "Pläne ansehen",
  },
  freePlan: {
    subject: "Du bist jetzt im Gistsmith-Free-Plan",
    preheader: "Was der Free-Plan jeden Monat enthält.",
    heading: "Willkommen im Free-Plan",
    intro: "Dein Testzeitraum ist vorbei, und dein Account ist jetzt im Free-Plan. Er läuft nicht ab.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} KI-Notizen pro Monat, für Meetings bis ${free.maxMeetingMinutes} Minuten`,
      `${free.asksPerMonth} Antworten von Fragen pro Monat`,
      "Transkripte, die auf deinem Gerät entstehen",
      "Die Gistsmith-Tastatur auf dem iPhone",
    ],
    outro: "Wenn du längere Meetings oder mehr Notizen brauchst, heben Personal und Pro die Grenzen an.",
    cta: "Pläne vergleichen",
  },
};
