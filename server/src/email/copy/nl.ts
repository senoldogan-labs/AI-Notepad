import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const nl: EmailCopy = {
  htmlLang: "nl",
  footer: {
    lifecycleReason: "Je krijgt deze e-mail omdat je tips en herinneringen van Gistsmith hebt gevraagd.",
    unsubscribe: "Afmelden",
    inApp: "of zet het uit in Gistsmith › Instellingen › Account.",
    confirmReason:
      "Iemand heeft dit adres in Gistsmith ingevuld. Was jij het niet, negeer deze e-mail dan: zonder klik op de link sturen we niets meer, en we verwijderen het adres binnen 7 dagen.",
    notMe: "Dit was ik niet",
    privacy: (address: string): string => `Vragen over privacy: ${address}`,
    privacyPolicy: "Privacybeleid",
    country: "Finland",
    reply: "Vragen? Beantwoord deze e-mail.",
    linkFallback: "Werkt de knop niet? Open dan deze link:",
  },
  confirm: {
    subject: "Bevestig je e-mailadres voor Gistsmith",
    preheader: "Eén klik voor tips van Gistsmith en de herinnering aan je proefperiode.",
    heading: "Bevestig je e-mailadres",
    body: [
      "Je hebt Gistsmith gevraagd je een paar tips te sturen en een herinnering voordat je gratis proefperiode afloopt.",
      "Bevestig dit adres en we beginnen. We sturen niets anders, en je kunt altijd stoppen.",
    ],
    cta: "Bevestig mijn e-mailadres",
    note: "De link is 7 dagen geldig.",
  },
  welcome: {
    subject: "Je eerste vergadering met Gistsmith",
    preheader: "Neem een vergadering op en krijg de notitie als die afloopt.",
    heading: "Welkom bij Gistsmith",
    body: [
      "De snelste manier om te zien wat Gistsmith doet, is één echte vergadering. Begint je volgende gesprek, klik dan op je Mac in Gistsmith op Start opname, of open Gistsmith op je iPhone en tik op Start opname.",
      "Als de vergadering afloopt, krijg je het transcript, een korte notitie en de actiepunten.",
      "Op de iPhone typ je met het Gistsmith-toetsenbord met je stem in elke app. Het is gratis: zet het aan in Gistsmith › Instellingen › Toetsenbord.",
    ],
    cta: "Neem een vergadering op",
  },
  activation: {
    subject: "Klaar voor je eerste vergadering?",
    preheader: "Je gratis proefperiode begint pas bij je eerste vergadering.",
    heading: "Je proefperiode is nog niet begonnen",
    body: (trial: TrialFacts): readonly string[] => [
      `Je hebt je aangemeld bij Gistsmith, maar nog geen vergadering opgenomen. Geen probleem: je gratis proefperiode (${trial.meetings} vergaderingen of ${trial.days} dagen) begint pas bij je eerste vergadering.`,
      "Start bij je volgende gesprek in Zoom, Teams of Google Meet, of een vergadering op locatie, de opname in Gistsmith. De notitie is klaar als de vergadering afloopt.",
      "Dit is de enige herinnering die we hierover sturen.",
    ],
    cta: "Neem een vergadering op",
  },
  trialEnding: {
    subject: "Je proefperiode van Gistsmith loopt bijna af",
    preheader: "Wat er daarna met je vergaderingen en notities gebeurt.",
    heading: "Je proefperiode loopt bijna af",
    oneMeetingLeft: "Je hebt nog één gratis proefvergadering.",
    endsWithinDay: "Je gratis proefperiode loopt binnen een dag af.",
    nextFree: (free: FreePlanFacts): string =>
      `Daarna gaat je account vanzelf over op het gratis abonnement: ${free.notesPerMonth} AI-notities per maand voor vergaderingen tot ${free.maxMeetingMinutes} minuten, en ${free.asksPerMonth} antwoorden van Vraag per maand.`,
    nextSubscribe: "Daarna heb je een abonnement nodig om Gistsmith je vergaderingen te laten blijven uitschrijven en notities te laten maken.",
    keep: "Je vergaderingen en notities blijven hoe dan ook op je apparaten.",
    cta: "Bekijk abonnementen",
  },
  freePlan: {
    subject: "Je zit nu op het gratis abonnement van Gistsmith",
    preheader: "Wat het gratis abonnement elke maand bevat.",
    heading: "Welkom bij het gratis abonnement",
    intro: "Je proefperiode is voorbij, en je account staat nu op het gratis abonnement. Het verloopt niet.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} AI-notities per maand, voor vergaderingen tot ${free.maxMeetingMinutes} minuten`,
      `${free.asksPerMonth} antwoorden van Vraag per maand`,
      "Transcripten die op je apparaat worden gemaakt",
      "Het Gistsmith-toetsenbord op de iPhone",
    ],
    outro: "Heb je langere vergaderingen of meer notities nodig, dan verhogen Personal en Pro de limieten.",
    cta: "Vergelijk abonnementen",
  },
};
