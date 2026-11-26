import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const it: EmailCopy = {
  htmlLang: "it",
  footer: {
    lifecycleReason: "Ricevi questa email perché hai chiesto consigli e promemoria di Gistsmith.",
    unsubscribe: "Annulla l’iscrizione",
    inApp: "oppure disattivali in Gistsmith › Impostazioni › Account.",
    confirmReason:
      "Qualcuno ha inserito questo indirizzo in Gistsmith. Se non sei stato tu, ignora questa email: senza un clic sul link non inviamo altro, e cancelliamo l’indirizzo entro 7 giorni.",
    notMe: "Non sono stato io",
    privacy: (address: string): string => `Domande sulla privacy: ${address}`,
    privacyPolicy: "Informativa sulla privacy",
    country: "Finlandia",
    reply: "Domande? Rispondi a questa email.",
    linkFallback: "Se il pulsante non funziona, apri questo link:",
  },
  confirm: {
    subject: "Conferma la tua email per Gistsmith",
    preheader: "Un clic per ricevere i consigli di Gistsmith e il promemoria della prova.",
    heading: "Conferma la tua email",
    body: [
      "Hai chiesto a Gistsmith di inviarti qualche consiglio e un promemoria prima che finisca la prova gratuita.",
      "Conferma questo indirizzo e iniziamo. Non inviamo nient’altro e puoi smettere quando vuoi.",
    ],
    cta: "Conferma la mia email",
    note: "Il link è valido per 7 giorni.",
  },
  welcome: {
    subject: "La tua prima riunione con Gistsmith",
    preheader: "Registra una riunione e ricevi la nota quando finisce.",
    heading: "Benvenuto in Gistsmith",
    body: [
      "Il modo più rapido per vedere cosa fa Gistsmith è una riunione vera. Quando inizia la prossima chiamata, fai clic su Avvia registrazione in Gistsmith sul Mac, oppure apri Gistsmith sull’iPhone e tocca Avvia registrazione.",
      "Alla fine della riunione ricevi la trascrizione, una breve nota e le cose da fare.",
      "Sull’iPhone, la Tastiera Gistsmith ti fa scrivere con la voce in qualsiasi app. È gratuita: attivala in Gistsmith › Impostazioni › Tastiera.",
    ],
    cta: "Registra una riunione",
  },
  activation: {
    subject: "Pronto per la tua prima riunione?",
    preheader: "La prova gratuita inizia con la tua prima riunione, non prima.",
    heading: "La tua prova non è ancora iniziata",
    body: (trial: TrialFacts): readonly string[] => [
      `Ti sei iscritto a Gistsmith ma non hai ancora registrato una riunione. Nessun problema: la prova gratuita (${trial.meetings} riunioni o ${trial.days} giorni) inizia solo con la tua prima riunione.`,
      "Alla prossima chiamata su Zoom, Teams o Google Meet, o in una riunione di persona, avvia la registrazione in Gistsmith. La nota è pronta quando la riunione finisce.",
      "È l’unico promemoria che inviamo al riguardo.",
    ],
    cta: "Registra una riunione",
  },
  trialEnding: {
    subject: "La tua prova di Gistsmith finisce presto",
    preheader: "Cosa succede dopo alle tue riunioni e note.",
    heading: "La tua prova finisce presto",
    oneMeetingLeft: "Ti resta una riunione di prova gratuita.",
    endsWithinDay: "La tua prova gratuita finisce entro un giorno.",
    nextFree: (free: FreePlanFacts): string =>
      `Dopo, il tuo account passa da solo al piano gratuito: ${free.notesPerMonth} note IA al mese per riunioni fino a ${free.maxMeetingMinutes} minuti e ${free.asksPerMonth} risposte di Chiedi al mese.`,
    nextSubscribe: "Dopo, serve un abbonamento perché Gistsmith continui a trascrivere le riunioni e a scrivere le note.",
    keep: "In ogni caso, le tue riunioni e le tue note restano sui tuoi dispositivi.",
    cta: "Vedi i piani",
  },
  freePlan: {
    subject: "Sei nel piano gratuito di Gistsmith",
    preheader: "Cosa include il piano gratuito ogni mese.",
    heading: "Benvenuto nel piano gratuito",
    intro: "La prova è finita e il tuo account ora è nel piano gratuito. Non scade.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} note IA al mese, per riunioni fino a ${free.maxMeetingMinutes} minuti`,
      `${free.asksPerMonth} risposte di Chiedi al mese`,
      "Trascrizioni scritte sul tuo dispositivo",
      "La Tastiera Gistsmith sull’iPhone",
    ],
    outro: "Quando ti servono riunioni più lunghe o più note, Personal e Pro alzano i limiti.",
    cta: "Confronta i piani",
  },
};
