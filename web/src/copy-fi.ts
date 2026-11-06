// Fince tanıtım sayfasının (`/fi`) metinleri. İngilizce metnin birebir çevirisi değildir: Finlandiya pazarına göre
// yazılmıştır (Teams/Zoom, suomi, EU-tietosuoja, ALV). Tip `HomeCopy`/`CommonCopy` olduğundan eksik metin derlemeyi
// durdurur. Ürün adı ve işletme bilgisi yine tek kaynaktan gelir (config.ts, legal/operator.ts).
import { cardStatementDescriptor, productName } from "./config";
import type { CommonCopy, HomeCopy } from "./copy";
import { operator } from "./legal/operator";
import { interfaceLanguages, noteLanguages, spokenLanguages } from "./lib/languages";

/** Sayfanın başlığındaki tek satır (paylaşım kartı ve alt bilgi de kullanır). */
const tagline: string = "Kuuntelee kokouksesi, kirjoittaa muistiinpanosi.";
/** Brändilause kahtena puolikkaana (ominaisuusosion kaksisävyinen otsikko). */
const brandQuiet: string = "Hiljaa, kun puhut";
const brandYours: string = "Sinun, kun lopetat.";
const brandLine: string = `${brandQuiet}. ${brandYours}`;

/** Fince arayüz metinleri: üst çubuk, alt bilgi ve ana sayfanın ortak düğmeleri. */
export const commonFi: CommonCopy = {
  skipLink: "Siirry sisältöön",
  homeLabel: `${productName} etusivu`,
  navLabel: "Päävalikko",
  nav: {
    features: "Ominaisuudet",
    pricing: "Hinnat",
    download: "Lataa",
    signIn: "Kirjaudu",
    account: "Tili",
    contact: "Ota yhteyttä",
    privacy: "Tietosuoja",
    terms: "Käyttöehdot",
    compare: "Vertailu",
    blog: "Blogi",
    mcp: "MCP tekoälysovelluksille",
    languages: "Kielet",
    integrations: "Integraatiot",
    dataHandling: "Tietojen käsittely",
  },
  downloadCta: "Lataa Macille",
  headerDownload: "Lataa",
  darkMode: "Tumma tila",
  // Hinta pysyy dollarina (checkout veloittaa dollareina); structured-data.ts tämän muodon lukee.
  price: "$5.99",
  perMonth: "/ kk",
  yearlyPrice: "$49",
  offer: "3 kokousta tai 7 päivää ilmaiseksi, sitten 5,99 $ kuussa tai 49 $ vuodessa, verot sisältyvät",
  trial: "Ilmainen kokeilu: 3 kokousta tai 7 päivää ensimmäisestä kokouksesta, kumpi tahansa täyttyy ensin, kukin enintään 90 minuuttia; korttia ei tarvita",
  requirementsShort: "macOS 15 tai uudempi · Apple silicon",
  macOnly: {
    notMacTitle: `${productName} on Mac-sovellus`,
    notMacText: "Se toimii Maceissa, joissa on Apple silicon -siru ja macOS 15 tai uudempi. Lähetä linkki itsellesi ja lataa sovellus Macillasi.",
    intelTitle: "Tässä Macissa on Intel-suoritin",
    intelText: `${productName} vaatii Macin, jossa on Apple silicon -siru (M1 tai uudempi), joten se ei avaudu tässä Macissa.`,
    oldMacosTitle: `${productName} vaatii macOS 15:n tai uudemman`,
    oldMacosText: `Tässä Macissa on macOS {version}. Päivitä se kohdasta Järjestelmäasetukset › Yleiset › Ohjelmistopäivitys ja lataa sitten ${productName}.`,
    copyLink: "Kopioi linkki",
    copied: "Linkki kopioitu",
    copyFailed: "Kopiointi ei onnistunut. Linkki on gistsmith.com/download",
    share: "Jaa linkki",
    email: "Lähetä sähköpostiini",
    emailSubject: `${productName} Macille`,
    downloadAnyway: "Lataa silti",
    close: "Sulje",
  },
  renewalNote: "Jatkuu automaattisesti kuukausittain tai vuosittain, kunnes peruutat. Voit peruuttaa milloin tahansa.",
  ogImageAlt: `${productName}-logo ja tunnuslause ”${tagline}” pehmeällä pastelligradientilla pienen ääniaallon yläpuolella.`,
  footer: {
    tagline: brandLine,
    madeIn: "Tehty Oulussa.",
    product: "Tuote",
    learn: "Lue lisää",
    account: "Tili",
    company: "Yritys",
    fontLicense: "Inter-fontin lisenssi",
    serifFontLicense: "Newsreader-fontin lisenssi",
    cookies: "Evästeet",
    pullThanks: "Kiitos, kun kuuntelit.",
    copyright: `© 2026 ${operator.name}`,
    language: "Kieli",
  },
  lastUpdated: "Päivitetty",
  contents: "Tällä sivulla",
};

/** Kokousmuistiinpanoista kertova Fince sivu. */
export const homeFi: HomeCopy = {
  meta: {
    title: `${productName} — kokousmuistiinpanot Macilla, ilman bottia`,
    description: `${brandLine} Kokousmuistiinpanot Macille: litterointi, käännös ja tehtäväsi ensin. Kokoukseen ei liity bottia.`,
  },
  eyebrow: "Kokousmuistiinpanot Macille",
  title: tagline,
  lead: "Kokoukseen ei liity bottia.",
  secondaryCta: "Katso hinnat",
  assurances: ["3 kokousta tai 7 päivää ilmaiseksi", "Ei korttitietoja"],
  proof: ["Tehty Oulussa", "EU-yritys", "Applen notarisoima", "Ei botteja puheluissasi"],
  demo: {
    label: `${productName} tallentaa kokousta ja kirjoittaa muistiinpanoa`,
    listening: "Kuuntelee",
    writing: "Kirjoittaa muistiinpanoa",
    done: "Muistiinpano valmis",
    timerMinutes: "42",
    transcriptTitle: "Litterointi",
    notePending: "Muistiinpanosi ilmestyy tähän, kun kokous päättyy.",
    transcript: [
      { speaker: "Mikko", text: "Avataan beta 14. marraskuuta.", translation: null },
      { speaker: "Sinä", text: "Sopii. Kirjoitan julkaisumuistiinpanot perjantaihin mennessä.", translation: null },
      { speaker: "Alex", text: "Can you send the pricing table to Ayşe?", translation: "Voitko lähettää hinnaston Ayşelle?" },
    ],
    meetingTitle: "Tuotepalaveri",
    meetingMeta: "Tänään · 42 min · 4 henkeä",
    tasksTitle: "Sinun tehtäväsi",
    tasks: ["Kirjoita beta-julkaisun muistiinpanot perjantaihin mennessä", "Lähetä hinnasto Ayşelle", "Sovi keskiviikon puhelu asiakastuen kanssa"],
    decisionsTitle: "Päätökset",
    decision: "Beta avataan 14. marraskuuta.",
    pause: "Keskeytä esittely",
    play: "Toista esittely",
    replay: "Toista esittely alusta",
  },
  launchVideo: {
    description: `Minuutin kierros ${productName}-sovelluksessa: litterointi ja käännös kokouksen aikana, muistiinpano jossa tehtävät ovat päällimmäisenä, kysyminen kaikista kokouksista ja muistiinpanojen lähettäminen sinne, missä tiimi työskentelee.`,
    fallback: "Selaimesi ei voi toistaa tätä videota tässä.",
    fallbackLink: "Avaa videotiedosto",
    pause: "Keskeytä video",
    play: "Toista video",
  },
  library: {
    label: "Viimeisimmät kokoukset",
    meetings: [
      { title: "Päiväpalaveri · Web-tiimi", template: "Päiväpalaveri", when: "Tänään · 15 min", tasks: "4 tehtävää", decisions: "1 päätös", nextTask: "Vie hinnastosivun katselmointi eteenpäin" },
      { title: "Asiakaspuhelu · Nordia", template: "Asiakaspuhelu", when: "Eilen · 38 min", tasks: "3 tehtävää", decisions: "2 päätöstä", nextTask: "Lähetä päivitetty tarjous perjantaihin mennessä" },
      { title: "Sprintin 42 suunnittelu", template: "Sprintin suunnittelu", when: "Maanantaina · 55 min", tasks: "5 tehtävää", decisions: "3 päätöstä", nextTask: "Korjaa vientivirhe ennen julkaisua" },
      { title: "Kahden kesken: Elif", template: "Kahden kesken", when: "Viime viikolla · 30 min", tasks: "2 tehtävää", decisions: "1 päätös", nextTask: "Anna palautetta käyttöönoton kulusta" },
    ],
  },
  showcase: {
    eyebrow: brandQuiet,
    title: brandYours,
    live: {
      label: "Kokouksen aikana",
      title: "Jokainen lause heti, kun se sanotaan",
      text: "Jokainen lause on ruudulla sekunneissa, ja vieraskielisen puheen käännös suomeksi kulkee rinnalla.",
      alt: `Kuvakaappaus ${productName}-sovelluksen reaaliaikaisesta paneelista suomenkielisen kokouksen aikana: kunkin puhujan suomenkieliset lauseet ja niiden alla englanninkielinen käännös, omat puheenvuorosi englanniksi ja painike ”What did I miss?” paneelin alareunassa.`,
    },
    note: {
      label: "Kokouksen jälkeen",
      title: "Valmis, kun suljet puhelun",
      text: "Tehtäväsi tekijöineen ja määräaikoineen ovat ensimmäisenä, sitten yhteenveto, päätökset ja sanasto.",
      alt: `Tuotepalaverin muistiinpano ${productName}-sovelluksessa: vasemmalla luettelo viimeisimmistä kokouksista ja kokousotsikon sekä puhumisjärjestyksen alla kolme tehtävää määräaikoineen: julkaisumuistiinpanot perjantaihin mennessä, hinnasto Ayşelle tänään, viikoittainen puhelu asiakastuen kanssa keskiviikkona.`,
    },
    ask: {
      label: "Milloin tahansa myöhemmin",
      title: "Hae kaikista kokouksista",
      text: "Kysy kaikista kokouksistasi ja saat vastauksen, joka linkittää kokoukseen, josta se löytyi.",
      alt: `Kysy-sivu ${productName}-sovelluksessa: kysymys ”What did we decide about the budget?” ja vastaus kahdella ranskalaisella viivalla ja numeroiduilla lähteillä, sekä rivi joka kertoo 3 lähteestä kahdessa kokouksessa.`,
    },
  },
  features: {
    missed: {
      title: "Pysy kärryillä keskeyttämättä",
      text: "”Mitä jäi välistä?” kertoo yhdellä napsautuksella viimeisten minuuttien olennaiset asiat, eikä kenenkään tarvitse toistaa itseään.",
      button: "Mitä jäi välistä?",
      answer: "Viimeisen 5 minuutin aikana: beta siirtyi 14. marraskuuta ja julkaisumuistiinpanot ovat sinulla.",
    },
    followUp: {
      title: "Jatkosähköposti valmiina",
      text: "Yksi napsautus luonnostelee jatkosähköpostin muistiinpanosta päätöksineen ja tekijöineen, valmiina muokattavaksi tai avattavaksi Mailissa.",
      recipe: "Jatkosähköposti",
      subject: "Aihe: Tuotepalaveri, seuraavat askeleet",
      lines: ["Beta avataan 14. marraskuuta.", "Alex: julkaisumuistiinpanot perjantaihin mennessä."],
    },
    templates: {
      title: "Oikea muistiinpano jokaiseen kokoukseen",
      text: "Asiakaspuhelu, kahden kesken, päiväpalaveri ja työhaastattelu saavat kukin muistiinpanon, jossa oikeat asiat ovat ensimmäisenä, tai kirjoita oma pohjasi.",
      sample: ["Asiakaspuhelu", "Kahden kesken", "Päiväpalaveri", "Sprintin suunnittelu", "Työhaastattelu", "Luento", "Oma pohja"],
    },
    voiceTyping: {
      title: "Sanele mihin tahansa sovellukseen",
      text: "Pidä pikanäppäintä pohjassa ja puhu: sanasi kirjoitetaan sinne, missä kursori on, tekstiksi Macillasi ja maksutta millä tahansa tilillä.",
      shortcut: "Pidä ⌃⌥D",
      sample: "Kiitos, lähetän hinnaston perjantaihin mennessä.",
    },
    screens: {
      title: "Palaute oikeaan diaan",
      text: "Verkkopalaverissa jaetun näytön kuvat yhdistetään siihen, mitä samaan aikaan puhuttiin, joten jokainen kommentti osuu oikeaan diaan.",
      frame: "Hinnastosivu",
      time: "12:40",
      quote: "Vuosihinnan valitsinta on vaikea huomata.",
    },
  },
  capabilities: {
    title: "Kaikissa tilauksissa myös",
    items: [
      "kaikki puhelusovellukset",
      "pysähtyy, kun puhelu päättyy",
      "puhujien nimet",
      "avoimet tehtävät mukana",
      `${spokenLanguages.length} puhuttua kieltä`,
      "kasvokkaiset kokoukset ja tiedostot",
    ],
    link: "Kaikki, mitä tilaukseen sisältyy",
  },
  trust: {
    eyebrow: "Tietosuoja",
    title: "Kokouksesi pysyvät sinun.",
    lead: "Tehty keskusteluille, jotka haluat pitää omana tietonasi – suomalaisessa pienyrityksessä, EU:n tietosuojalainsäädännön alla.",
    items: [
      {
        icon: "laptop",
        title: "Tiedot Macillasi",
        text: "Muistiinpanot, litteroinnit ja tallenteet ovat omalla Macillasi. Palvelimemme eivät tallenna ääntäsi, eivätkä muistiinpanojasi, ellet ota käyttöön tekoälyavustajien pääsyä.",
      },
      { icon: "sparkle", title: "Ei tekoälyn koulutusmateriaalina", text: "Kokouksiasi ei käytetä palveluntarjoajiemme mallien kouluttamiseen. Olemme kieltäneet sen kaikkialla, missä se on asetuksissa mahdollista." },
      { icon: "globe", title: "EU-yritys, GDPR", text: "Toimimme Suomesta käsin EU:n tietosuojalainsäädännön alla, ja tilitietokantamme sijaitsee EU:ssa." },
      { icon: "check-circle", title: "Poista milloin haluat", text: "Poista tilisi sovelluksessa tai verkkosivuilla milloin tahansa; verkossa tai Macilla ostettu tilaus päättyy samalla." },
    ],
    link: "Lue tietosuojaseloste",
  },
  noteCallouts: {
    dueDate: "Tekijä ja määräaika",
    transcript: "Koko litterointi puhujittain",
  },
  integrations: {
    eyebrow: "Integraatiot",
    title: "Kokouksesi siellä, missä työ tapahtuu.",
    lead: "Lähetä muistiinpano sinne, missä tiimi työskentelee, siirrä tehtävät omaan työkaluusi ja anna tekoälysovellustesi lukea kokouksiasi.",
    notes: {
      title: "Muistiinpanot tiimille",
      text: "Lähetä muistiinpano Notioniin, Apple Notesiin, Slackiin, Microsoft Teamsiin, Discordiin tai Zoomin Team Chatiin, tai minne tahansa webhookilla.",
    },
    tasks: {
      title: "Tehtävät omaan työkaluun",
      text: "Muunna tehtäväsi Linear- tai Jira-tiketeiksi tai Apple Remindersiin.",
    },
    ai: {
      title: "Tekoälysovelluksesi MCP:n kautta",
      text: "Claude, Cursor ja VS Code voivat hakea ja lukea kokouksiasi, mutta eivät muuttaa niitä.",
    },
    mcpLink: "Miten MCP toimii",
    files: {
      title: "Tiedostosi ja kalenterisi",
      text: "Tallenna muistiinpanot Markdownina kansioon, kuten Obsidian-holviin, vie PDF-, Word- tai tekstitystiedostoksi ja anna kalenterin aloittaa tallennus.",
    },
    mcpDemo: {
      label: "Claudessa",
      question: "Mitä lupasin Nordialle viime viikolla?",
      tool: "Haki kokouksistasi",
      answerLead: "27. lokakuun asiakaspuhelussa lupasit:",
      answer: ["Lähettää päivitetyn tarjouksen perjantaihin mennessä", "Jakaa käyttöönoton tarkistuslistan"],
      source: "Asiakaspuhelu · Nordia",
    },
  },
  pricingTitle: "Yksi hinta, kuukausittain tai vuosittain.",
  pricingLead: "Yksi paketti, jossa on kaikki, laskutetaan kuukausittain tai vuosittain. Kokeile omilla kokouksillasi ennen kuin maksat.",
  pricingCta: "Hintatiedot",
  pricingCompare: "Vertaa Granolaan, Otteriin, Firefliesiin ja Poffleen",
  faqTitle: "Kysymyksiä",
  faq: [
    {
      question: "Miten ilmainen kokeilu toimii?",
      answer:
        "Kokeilu on maksuton eikä vaadi korttia: 3 kokousta tai 7 päivää ensimmäisestä kokouksesta, kumpi täyttyy ensin. Käyttämättömät kokeilukokoukset vanhenevat silloin. Yksi kokeilukokous voi kestää enintään 90 minuuttia. Sen jälkeen tilaus maksaa 5,99 $ kuussa tai 49 $ vuodessa, verot sisältyvät hintaan.",
    },
    {
      question: "Liittyykö kokoukseeni botti?",
      answer: `Ei. ${productName} kuuntelee Macisi ääntä ja mikrofonia, eivätkä osallistujat näe kokouksessa mitään bottia. Sovellus muistuttaa kertomaan osallistujille ennen kuin aloitat tallennuksen.`,
    },
    {
      question: "Minne ääneni menee?",
      answer:
        "Tallennuksen aikana ääni siirtyy Maciltasi Deepgramille reaaliaikaista litterointia varten; Deepgramia on pyydetty olemaan säilyttämättä ääntä ja käyttämättä sitä kouluttamiseen. Jos tämä ei ole käytettävissä, litterointi tehdään Macillasi. Kokouksen päätyttyä ääni kulkee palvelimemme kautta ElevenLabsille, joka erottelee puhujat ja tuottaa lopullisen litteroinnin; muistiinpanoja ja käännöstä varten teksti menee Anthropicin Claude-mallille. Palvelimemme eivät tallenna ääntä, eivätkä muistiinpanoja, ellet ota käyttöön tekoälyavustajien pääsyä: ne laskevat keston ja pitävät lopullisen litteroinnin salattuna, jotta se voidaan lähettää uudelleen 2 tunnin ajan, jos yhteys katkeaa; se poistetaan seuraavassa päivittäisessä siivouksessa, noin vuorokauden kuluessa. ElevenLabs ja Anthropic voivat säilyttää käsittelemänsä aineiston oman käytäntönsä mukaisen ajan (Anthropic poistaa sen 30 päivän kuluessa). Jos otat käyttöön asetuksen ”Käytä näyttökuvia muistiinpanoissa”, enintään kuusi kokouksen näyttökuvaa lähetetään Anthropicille litteroinnin mukana muistiinpanoa kirjoitettaessa ja enintään kolme, kun kysyt Kysy-sivulla kokouksen siitä kohdasta; muuten kuvat eivät koskaan lähde Macistasi. Tietosuojaselosteessa on yksityiskohdat.",
    },
    {
      question: "Mitä kieliä tuetaan?",
      answer: `Kokouksessa voi puhua ${spokenLanguages.length} kieltä, muun muassa suomea, ruotsia, englantia ja turkkia, ja muistiinpanot ja käännökset saat ${noteLanguages.length} kielellä. Valitset itse muistiinpanojen ja käännösten kielen kokouksen kielestä riippumatta. Itse sovellus on käytettävissä ${interfaceLanguages.length} kielellä, myös suomeksi: se seuraa Macin kieltä, ja kielen voi vaihtaa kohdassa Asetukset › Yleiset.`,
    },
    {
      question: "Toimiiko se myös kasvokkaisissa kokouksissa ja tallenteilla?",
      answer: "Toimii. Kytke sovelluksessa päälle ”Kasvokkain” ennen kuin aloitat, niin Macin mikrofoni tallentaa kaikki huoneessa olevat. Voit myös tuoda ääni- tai videotiedoston, kuten tallennetun puhelun tai ääniviestin, ja saat siitä saman litteroinnin ja muistiinpanon; tuotu tiedosto lasketaan kokoukseksi.",
    },
    {
      question: "Miten maksu ja verot toimivat Suomessa?",
      answer: `Maksun hoitaa Stripe ja myynnin Link, Stripen maksupalvelu. Hinta 5,99 $ kuussa tai 49 $ vuodessa sisältää arvonlisäveron: Link laskee sijaintisi mukaisen veron ja tilittää sen puolestamme, ja kassa näyttää sisältyvän veron ennen maksua. Kassalla hinta voi näkyä myös euroina. Veloitus näkyy tiliotteellasi nimellä ${cardStatementDescriptor}, ja kuitti tulee Linkiltä sähköpostiisi. Korttitietosi jäävät Stripelle ja Linkille eivätkä koskaan tule meille.`,
    },
  ],
  featureList: [
    "Tallentaa verkkokokoukset (Zoom, Microsoft Teams, Google Meet ja muut sovellukset) ilman bottia sekä kasvokkaiset kokoukset ja tuodut ääni- tai videotiedostot",
    "Lopettaa tallennuksen, kun puhelu päättyy, 30 sekunnin lähtölaskennan jälkeen; ”Jatka nauhoitusta” jatkaa tallennusta, ja toiminnon voi kytkeä pois asetuksista",
    `Litterointi livenä ${spokenLanguages.length} kielellä ja käännös livenä ${noteLanguages.length} kielelle, joka välittää puhujan tarkoituksen eikä käännä sana sanalta`,
    `Sovellus ${interfaceLanguages.length} kielellä, myös suomeksi; kieli seuraa Macin kieltä`,
    "Muistiinpano jokaisen kokouksen jälkeen: ensin tehtäväsi tekijöineen ja määräaikoineen, sitten yhteenveto, aiheet, päätökset ja sanasto",
    "Avoimet tehtävät saman sarjan tai samojen ihmisten aiemmista kokouksista, kun tallennat kokouksen kalenterista",
    "Kokousmallit, jotka valitaan kokouksen nimestä (esimerkiksi kahden kesken, päiväpalaveri ja sprintin suunnittelu), ja valmiit ohjeet yhdellä napsautuksella",
    "Jatkosähköposti muistiinpanosta: tärkeimmät asiat, päätökset ja tehtävät tekijöineen ja määräaikoineen, valmiina muokattavaksi, kopioitavaksi tai avattavaksi Mailissa",
    "”Mitä jäi välistä?” -yhteenvedot kesken kokouksen",
    "Kysy kaikista kokouksistasi tai vain @-merkillä valituista, vastaukset lähdeviitteineen; kopioi vastaus tai tallenna se Markdown-tiedostoksi",
    "Halutessasi verkkohaku Kysy-toiminnossa asioille, joita kokouksistasi ei löydy, ja verkkosivut lähteinä",
    "Jatkokysymykset, jotka muistavat keskustelun ja kysytyt kokoukset; tallennetut keskustelut, joita voit nimetä, hakea ja suodattaa",
    "Halutessasi kuvat jaetusta näytöstä, yhdistettynä siihen, mitä puhuttiin",
    "Muistiinpanot Slackiin, Microsoft Teamsiin, Discordiin, Zoom Team Chatiin, Notioniin ja Apple Notesiin; tehtävät Lineariin, Jiraan ja Apple Remindersiin; kaikkeen muuhun webhookilla",
    "Vain luku -MCP-palvelin Claudelle, Cursorille ja VS Codelle",
    "Sanelu mihin tahansa Mac-sovellukseen, puheentunnistus Macilla",
    "Muistiinpanot, litteroinnit ja tallenteet tallennetaan Macillesi",
  ],
  finalTitle: "Anna sen kirjoittaa muistiinpano seuraavasta kokouksestasi.",
  finalLead: "Käyttöönotto vie minuutin, sen jälkeen riittää että aloitat kuuntelemisen.",
};
