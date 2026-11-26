import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const fi: EmailCopy = {
  htmlLang: "fi",
  footer: {
    lifecycleReason: "Saat tämän viestin, koska pyysit Gistsmithin vinkkejä ja muistutuksia.",
    unsubscribe: "Peru tilaus",
    inApp: "tai poista ne käytöstä kohdassa Gistsmith › Asetukset › Tili.",
    confirmReason:
      "Joku syötti tämän osoitteen Gistsmithiin. Jos se et ollut sinä, jätä tämä viesti huomiotta: mitään ei lähetetä ilman linkin klikkausta, ja poistamme osoitteen 7 päivän kuluessa.",
    notMe: "Tämä en ollut minä",
    privacy: (address: string): string => `Tietosuojakysymykset: ${address}`,
    privacyPolicy: "Tietosuojaseloste",
    country: "Suomi",
    reply: "Kysyttävää? Vastaa tähän viestiin.",
    linkFallback: "Jos painike ei toimi, avaa tämä linkki:",
  },
  confirm: {
    subject: "Vahvista sähköpostiosoitteesi Gistsmithiin",
    preheader: "Yksi klikkaus, niin saat Gistsmithin vinkit ja muistutuksen kokeilustasi.",
    heading: "Vahvista sähköpostiosoitteesi",
    body: [
      "Pyysit Gistsmithiltä muutamia vinkkejä ja muistutuksen ennen kuin ilmainen kokeilusi päättyy.",
      "Vahvista tämä osoite, niin aloitamme. Emme lähetä mitään muuta, ja voit lopettaa milloin tahansa.",
    ],
    cta: "Vahvista sähköpostiosoite",
    note: "Linkki on voimassa 7 päivää.",
  },
  welcome: {
    subject: "Ensimmäinen kokouksesi Gistsmithillä",
    preheader: "Nauhoita kokous, niin saat muistiinpanon sen päätyttyä.",
    heading: "Tervetuloa Gistsmithiin",
    body: [
      "Nopein tapa nähdä, mitä Gistsmith tekee, on yksi oikea kokous. Kun seuraava puhelusi alkaa, valitse Macin Gistsmithissä Aloita nauhoitus tai avaa Gistsmith iPhonessa ja napauta Aloita nauhoitus.",
      "Kun kokous päättyy, saat litteroinnin, lyhyen muistiinpanon ja tehtävät.",
      "iPhonessa Gistsmith-näppäimistöllä voit kirjoittaa puhumalla missä tahansa apissa. Se on ilmainen: ota se käyttöön kohdassa Gistsmith › Asetukset › Näppäimistö.",
    ],
    cta: "Nauhoita kokous",
  },
  activation: {
    subject: "Valmis ensimmäiseen kokoukseesi?",
    preheader: "Ilmainen kokeilusi alkaa vasta ensimmäisestä kokouksesta.",
    heading: "Kokeilusi ei ole vielä alkanut",
    body: (trial: TrialFacts): readonly string[] => [
      `Rekisteröidyit Gistsmithiin, mutta et ole vielä nauhoittanut kokousta. Ei hätää: ilmainen kokeilusi (${trial.meetings} kokousta tai ${trial.days} päivää) alkaa vasta ensimmäisestä kokouksestasi.`,
      "Aloita nauhoitus Gistsmithissä seuraavassa Zoom-, Teams- tai Google Meet -puhelussa tai kasvokkaisessa kokouksessa. Muistiinpano on valmis, kun kokous päättyy.",
      "Tämä on ainoa muistutus, jonka lähetämme tästä.",
    ],
    cta: "Nauhoita kokous",
  },
  trialEnding: {
    subject: "Gistsmith-kokeilusi päättyy pian",
    preheader: "Mitä kokouksillesi ja muistiinpanoillesi tapahtuu sen jälkeen.",
    heading: "Kokeilusi päättyy pian",
    oneMeetingLeft: "Sinulla on yksi ilmainen kokeilukokous jäljellä.",
    endsWithinDay: "Ilmainen kokeilusi päättyy vuorokauden sisällä.",
    nextFree: (free: FreePlanFacts): string =>
      `Sen jälkeen tilisi siirtyy itsestään ilmaiseen tilaukseen: ${free.notesPerMonth} tekoälymuistiinpanoa kuukaudessa enintään ${free.maxMeetingMinutes} minuutin kokouksista ja ${free.asksPerMonth} Kysy-vastausta kuukaudessa.`,
    nextSubscribe: "Sen jälkeen tarvitset tilauksen, jotta Gistsmith jatkaa kokoustesi litterointia ja muistiinpanojen kirjoittamista.",
    keep: "Kokouksesi ja muistiinpanosi pysyvät laitteillasi joka tapauksessa.",
    cta: "Katso tilaukset",
  },
  freePlan: {
    subject: "Olet nyt Gistsmithin ilmaisessa tilauksessa",
    preheader: "Mitä ilmainen tilaus sisältää joka kuukausi.",
    heading: "Tervetuloa ilmaiseen tilaukseen",
    intro: "Kokeilusi on päättynyt, ja tilisi on nyt ilmaisessa tilauksessa. Se ei vanhene.",
    items: (free: FreePlanFacts): readonly string[] => [
      `${free.notesPerMonth} tekoälymuistiinpanoa kuukaudessa enintään ${free.maxMeetingMinutes} minuutin kokouksista`,
      `${free.asksPerMonth} Kysy-vastausta kuukaudessa`,
      "Laitteellasi kirjoitetut litteroinnit",
      "Gistsmith-näppäimistö iPhonessa",
    ],
    outro: "Kun tarvitset pidempiä kokouksia tai enemmän muistiinpanoja, Personal ja Pro nostavat rajoja.",
    cta: "Vertaa tilauksia",
  },
};
