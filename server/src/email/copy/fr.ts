import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const fr: EmailCopy = {
  htmlLang: "fr",
  footer: {
    lifecycleReason: "Vous recevez cet e-mail parce que vous avez demandé les conseils et rappels de Gistsmith.",
    unsubscribe: "Se désabonner",
    inApp: "ou désactivez-les dans Gistsmith › Réglages › Compte.",
    confirmReason:
      "Quelqu’un a saisi cette adresse dans Gistsmith. Si ce n’est pas vous, ignorez simplement cet e-mail : rien d’autre n’est envoyé sans clic sur le lien, et nous supprimons l’adresse sous 7 jours.",
    notMe: "Ce n’était pas moi",
    privacy: (address: string): string => `Questions sur la confidentialité : ${address}`,
    privacyPolicy: "Politique de confidentialité",
    country: "Finlande",
    reply: "Une question ? Répondez à cet e-mail.",
    linkFallback: "Si le bouton ne fonctionne pas, ouvrez ce lien :",
  },
  confirm: {
    subject: "Confirmez votre e-mail pour Gistsmith",
    preheader: "Un clic pour recevoir les conseils de Gistsmith et le rappel de votre essai.",
    heading: "Confirmez votre e-mail",
    body: [
      "Vous avez demandé à Gistsmith de vous envoyer quelques conseils et un rappel avant la fin de votre essai gratuit.",
      "Confirmez cette adresse et nous commençons. Nous n’envoyons rien d’autre, et vous pouvez arrêter à tout moment.",
    ],
    cta: "Confirmer mon e-mail",
    note: "Le lien est valable 7 jours.",
  },
  welcome: {
    subject: "Votre première réunion avec Gistsmith",
    preheader: "Enregistrez une réunion et recevez la note à la fin.",
    heading: "Bienvenue dans Gistsmith",
    body: [
      "Le plus rapide pour voir ce que fait Gistsmith, c’est une vraie réunion. Au début de votre prochain appel, cliquez sur Démarrer l’enregistrement dans Gistsmith sur votre Mac, ou ouvrez Gistsmith sur votre iPhone et touchez Démarrer l’enregistrement.",
      "À la fin de la réunion, vous recevez la transcription, une note courte et les actions à faire.",
      "Sur l’iPhone, le Clavier Gistsmith vous permet d’écrire à la voix dans n’importe quelle app. Il est gratuit : activez-le dans Gistsmith › Réglages › Clavier.",
    ],
    cta: "Enregistrer une réunion",
  },
  activation: {
    subject: "Prêt pour votre première réunion ?",
    preheader: "Votre essai gratuit commence avec votre première réunion, pas avant.",
    heading: "Votre essai n’a pas encore commencé",
    body: (trial: TrialFacts): readonly string[] => [
      `Vous vous êtes inscrit à Gistsmith mais n’avez pas encore enregistré de réunion. Aucun souci : votre essai gratuit (${trial.meetings} réunions ou ${trial.days} jours) ne commence qu’avec votre première réunion.`,
      "Lors de votre prochain appel Zoom, Teams ou Google Meet, ou d’une réunion en personne, lancez l’enregistrement dans Gistsmith. La note est prête à la fin de la réunion.",
      "C’est le seul rappel que nous envoyons à ce sujet.",
    ],
    cta: "Enregistrer une réunion",
  },
  trialEnding: {
    subject: "Votre essai Gistsmith se termine bientôt",
    preheader: "Ce qui arrive ensuite à vos réunions et à vos notes.",
    heading: "Votre essai se termine bientôt",
    oneMeetingLeft: "Il vous reste une réunion d’essai gratuite.",
    endsWithinDay: "Votre essai gratuit se termine dans moins d’un jour.",
    nextFree: (free: FreePlanFacts): string =>
      `Ensuite, votre compte passe automatiquement à l’offre gratuite : ${free.notesPerMonth} notes IA par mois pour des réunions jusqu’à ${free.maxMeetingMinutes} minutes, et ${free.asksPerMonth} réponses de Demander par mois.`,
    nextSubscribe: "Ensuite, un abonnement permet à Gistsmith de continuer à transcrire vos réunions et à écrire les notes.",
    keep: "Dans tous les cas, vos réunions et vos notes restent sur vos appareils.",
    cta: "Voir les offres",
  },
  freePlan: {
    subject: "Vous êtes sur l’offre gratuite de Gistsmith",
    preheader: "Ce que l’offre gratuite comprend chaque mois.",
    heading: "Bienvenue dans l’offre gratuite",
    intro: "Votre essai est terminé et votre compte est maintenant sur l’offre gratuite. Elle n’expire pas.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} notes IA par mois, pour des réunions jusqu’à ${free.maxMeetingMinutes} minutes`,
      `${free.asksPerMonth} réponses de Demander par mois`,
      "Des transcriptions écrites sur votre appareil",
      "Le Clavier Gistsmith sur l’iPhone",
    ],
    outro: "Quand il vous faut des réunions plus longues ou plus de notes, Personal et Pro relèvent les limites.",
    cta: "Comparer les offres",
  },
};
