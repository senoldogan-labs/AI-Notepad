# Gistsmith for iPhone: localized product page metadata

Paste-ready App Store Connect metadata for **Turkish**, **Finnish** and **English (U.K.)**, next to the live
**English (U.S.)** page. Every claim matches the iPhone app as of 0.1.15 (28): it records only the conversation around
the iPhone with its microphone. It never records phone calls or online meetings, and it never joins a meeting.

Limits: App Name and Subtitle ≤ 30 characters, Promotional Text ≤ 170, Description ≤ 4000, Keywords ≤ 100 bytes
(comma-separated, no spaces after commas), What's New ≤ 4000. `node scripts/appstore-screenshots/metadata-check.ts docs/appstore/metadata.md docs/appstore/custom-product-pages.md` checks every block
in this file against those limits. Run it after each edit.

The app's interface is in **English and Turkish** only. Meetings can be held in 35 languages (Finnish first), and
notes, translations and answers can be written in 37. The Finnish page says plainly that the interface is in English,
so Finnish users don't expect a Finnish interface. The copy never says "unlimited", never says meetings sync between
iPhone and Mac (only the account and subscription are shared), and states the trial as "first 3 meetings or 7 days,
whichever comes first". Prices are not written in the
localized descriptions because the App Store shows each storefront's own price and currency. The U.S. description
keeps its USD prices.

## App Privacy label and App Review notes: AI assistant access

AI assistant access (Settings › Connections › AI assistant access, off by default) uploads an encrypted copy of each
meeting's notes (title, date, length, folder, attendee names, the AI note and the user's own notes; never audio,
transcripts, screen snapshots or voice profiles) so that AI assistants the user connects through
https://mcp.gistsmith.com/mcp can read them. The server can read this copy (encrypted at rest, not end to end).

- **App Privacy label** (App Store Connect › App Privacy), once a build with the setting ships: add **User Content ›
  Other User Content** (meeting notes), **Linked to You**, purpose **App Functionality**, not used for tracking. It is
  collected only when the user turns AI assistant access on; the label has no "optional" flag, so declare it, and the
  privacy policy (section 3) explains that it is off by default.
- **App Review notes** (App Review Information › Notes), one line:
  `AI assistant access (Settings › Connections) is off by default; when turned on, an encrypted copy of meeting notes (no audio or transcripts) is stored in the EU so AI assistants the user connects via OAuth at https://mcp.gistsmith.com/mcp can read them; turning it off deletes the copy at once.`
- **Descriptions**: the PRIVACY paragraphs below stay true while the server switch is off. When the owner launches
  the feature, replace their server sentence in the same update as the label:
  - en-GB: "…and our servers don't keep your audio, or notes we can read unless you turn on AI assistant access (off by
    default: an encrypted copy of your notes, never audio, kept in the EU so the assistants you connect can read
    them; turn it off and it is deleted at once). Optional Mac sync keeps only an end-to-end encrypted copy."
  - tr: "…sunucularımız sesini saklamaz; notlarını yalnızca yapay zekâ asistanı erişimini açarsan (varsayılan kapalı)
    AB'de şifreli bir kopya olarak saklar, bağladığın asistanlar okuyabilsin diye; kapatınca hemen silinir."
  - fi: "…eivätkä palvelimemme säilytä ääntäsi. Muistiinpanoistasi ne säilyttävät salatun kopion EU:ssa vain, jos
    otat käyttöön tekoälyavustajien pääsyn (oletuksena pois päältä); kun kytket sen pois, kopio poistetaan heti."

## Keyword strategy

- **Name + subtitle + keywords make one index per localization.** A word that is already in the name or subtitle
  gains nothing when it's repeated in keywords. The App Store also combines words across fields ("meeting" + "notes"),
  so single words beat phrases, and plurals and other word forms are only partly matched.
- **English (U.K.) also indexes in the U.S. store.** In the U.S. storefront, the App Store indexes the en-US and en-GB
  localizations together. That gives the en-GB fields a second set of 100 keyword bytes plus a subtitle for U.S.
  search, so the en-GB set below uses **no word from the U.S. keyword list**. It adds a British spelling
  (summarise), British office terms (minute taker, one-to-one, dictaphone) and synonyms (recap, speech,
  audio, seminar). The name stays the same as in the U.S. because it is the brand and is also the en-GB page's only
  name in the U.K. storefront.
- **The U.K. storefront indexes only en-GB.** So the en-GB subtitle carries the core terms a U.K. user types
  ("transcripts", "to-dos"), and the keywords cover the rest.
- **Turkish and Finnish are written for how people search, not translated.** In Finnish, compounds don't match
  their parts ("kokousmuistiinpanot" does not match "muistiinpanot"), so the keywords list the short base words
  separately. In Turkish, users type "ses kaydı", "deşifre" and "tutanak", not "transkripsiyon". Turkish keywords
  avoid duplicating the subtitle's word forms.
- **No competitor names** (Otter, Granola, Plaud, Fireflies, Notta, …) and no "Zoom/Teams/call" terms, because the
  iPhone app records in-person conversations only.
- Assumed **U.S. reference**: Name `Gistsmith: AI Meeting Notes`. U.S. keywords:
  `transcription,transcribe,minutes,recorder,summary,notetaker,voice memo,lecture,interview,record,1on1`. If the live
  U.S. name or subtitle differs, re-check the en-GB list against it so no word is duplicated.

---

## English (U.K.) — `en-GB`

### Name

```text
Gistsmith: AI Meeting Notes
```

### Subtitle

```text
Transcripts, recaps & to-dos
```

### Promotional Text

```text
Put your iPhone on the table. When the meeting ends, your note is ready: recap, decisions and to-dos. Ask anything about past meetings. First 3 meetings or 7 days free.
```

### Keywords

```text
dictaphone,summarise,minute taker,one-to-one,speech,audio,text,seminar,student,workshop,agenda
```

### Description

```text
Gistsmith turns the conversation around your iPhone into clear meeting notes. Put your phone on the table, tap record and keep talking. When the meeting ends, your note is ready: a summary, the decisions made and everyone's tasks.

Made for meetings in the room: one-to-ones, team meetings, client visits, interviews, lectures and workshops. Gistsmith listens through your iPhone's microphone. It doesn't record phone calls or online meetings, and there's no bot to invite.

RECORD
• Live transcript while you talk, with speakers separated
• Live translation into your note language when the meeting is in another language
• "What did I miss?" sums up the last few minutes while you're still recording
• Keeps recording in the background, with progress on the Lock Screen and in the Dynamic Island
• Start from the app, Control Centre, the Action button, a widget, Siri or Shortcuts
• Import audio or video recordings from Files or Photos

YOUR NOTE, READY WHEN THE MEETING ENDS
• A summary, the decisions and every task with its owner and due date
• A glossary and the topics in order, with timestamps
• Templates: General, One-on-one, Client meeting, Lecture / training, Job interview, or your own instructions
• Notes you add during the meeting shape the final note
• Edit with a plain instruction such as "shorten the summary"
• Share as PDF, web page, Markdown, plain text or SRT subtitles, or share the note in another language

ASK YOUR MEETINGS
• Ask across all your meetings; answers cite the meetings they came from
• Type "/" for recipes such as Follow-up email, Prep my day, Decisions and rationale, and Risks and open questions
• Before a meeting, a briefing on earlier meetings with the same people: decisions and open tasks

STAY ON TOP OF IT
• Your tasks from every meeting in one list; add any task to Reminders
• Meetings from your calendar for the next 12 hours, with an optional reminder a minute before
• People: name speakers once, then see each person's meetings, talk time and tasks
• Search titles, people and transcripts
• Make it yours: 7 themes, 5 accent colours, fonts and text size

ONE ACCOUNT FOR MAC AND IPHONE
One account and one subscription for Gistsmith on Mac and iPhone. Each device keeps the meetings it recorded.

LANGUAGES
Meetings in 35 languages. Notes, translations and answers in 37. The app itself is in English and Turkish.

PRIVACY
Your meetings are not used to train AI models. Audio is sent only to make the transcript and the note, and our servers don't keep your audio, or notes we can read (optional Mac sync keeps only an end-to-end encrypted copy). You choose how long recordings stay on your iPhone, from 7 to 365 days. Tell the people in the room before you record.

PRICING
Your first 3 meetings or 7 days are free, whichever comes first (sign-in required; trial meetings up to 90 minutes each). After that, Gistsmith Pro is a monthly or yearly auto-renewing subscription with 10 hours of recording a month (fair use) and up to 4 hours per meeting. The price for your country is shown in the app before you buy. Payment is charged to your Apple Account when you confirm. The subscription renews automatically unless you turn it off at least 24 hours before the end of the current period. Manage or cancel it in your Apple Account settings.

Terms of Use: https://gistsmith.com/terms
Privacy Policy: https://gistsmith.com/privacy
```

### What's New (template for 0.1.16-style updates)

Feature update: replace the bracketed lines with real, user-facing changes (see `docs/release-notes/`).

```text
Gistsmith 0.1.16 [one sentence: the main benefit of this update].

New
• [Feature]: [what you can do now, in one sentence].

Improvements
• [What works better for you].
• Fixes and reliability improvements.
```

Maintenance update:

```text
This update makes recording and note writing more reliable and fixes a few issues. Thanks for your feedback. Write to us from Settings › Send feedback.
```

---

## Turkish — `tr`

### Name

```text
Gistsmith: AI Toplantı Notları
```

### Subtitle

```text
Sesi yazıya döker ve özetler
```

### Promotional Text

```text
iPhone'unu masaya koy; toplantı bittiğinde notun hazır: özet, kararlar ve görevler. Geçmiş toplantılarına soru sor. İlk 3 toplantı ya da 7 gün ücretsiz.
```

### Keywords

```text
ses kaydı,deşifre,transkript,tutanak,ders,mülakat,görüşme,görev,birebir,not alma,sesli not
```

### Description

```text
Gistsmith, iPhone'unun çevresindeki konuşmayı net toplantı notlarına dönüştürür. Telefonunu masaya koy, kayda bas ve konuşmaya devam et. Toplantı bittiğinde notun hazır: özet, alınan kararlar ve herkesin görevleri.

Yüz yüze toplantılar için: birebir görüşmeler, ekip toplantıları, müşteri ziyaretleri, mülakatlar, dersler ve atölyeler. Gistsmith iPhone'unun mikrofonuyla dinler. Telefon görüşmelerini ya da çevrim içi toplantıları kaydetmez; davet edilecek bir bot da yok.

KAYIT
• Konuşurken canlı metin; konuşmacılar ayrı ayrı
• Toplantı başka bir dildeyse not dilinde canlı çeviri
• "Ne kaçırdım?" kayıt sürerken son birkaç dakikayı özetler
• Arka planda kayda devam eder; ilerleme kilit ekranında ve Dynamic Island'da
• Uygulamadan, Denetim Merkezi'nden, Eylem düğmesinden, widget'tan, Siri'yle ya da Kestirmeler'le başlat
• Dosyalar'dan ya da Fotoğraflar'dan ses ve video kayıtlarını içe aktar

TOPLANTI BİTTİĞİNDE NOTUN HAZIR
• Özet, kararlar ve sahibi ile tarihi belli her görev
• Sözlük ve zaman damgalı konu akışı
• Şablonlar: Genel, Birebir görüşme, Müşteri görüşmesi, Ders / eğitim, İş mülakatı ya da kendi yönergen
• Toplantı sırasında eklediğin notlar son nota yansır
• "Özeti kısalt" gibi düz bir yönergeyle düzenle
• PDF, web sayfası, Markdown, düz metin ya da SRT altyazı olarak paylaş; ya da notu başka bir dilde paylaş

TOPLANTILARINA SOR
• Tüm toplantılarına soru sor; cevap, dayandığı toplantıları gösterir
• "/" yazınca tarifler: Takip e-postası, Bugüne hazırlan, Kararlar ve gerekçeleri, Riskler ve açık sorular ve daha fazlası
• Toplantıdan önce aynı kişilerle yaptığın önceki toplantıların brifingi: kararlar ve açık görevler

HİÇBİR ŞEY KAÇMASIN
• Tüm toplantılardaki görevlerin tek listede; istediğini Anımsatıcılar'a ekle
• Takviminden önümüzdeki 12 saatin toplantıları ve istersen başlamadan bir dakika önce hatırlatma
• Kişiler: konuşmacılara bir kez ad ver; her kişinin toplantılarını, konuşma süresini ve görevlerini gör
• Başlıklarda, kişilerde ve transkriptlerde ara
• Kendine göre ayarla: 7 tema, 5 vurgu rengi, yazı tipi ve yazı boyutu

MAC VE IPHONE İÇİN TEK HESAP
Mac ve iPhone'da Gistsmith için tek hesap ve tek abonelik. Her cihaz kendi kaydettiği toplantıları saklar.

DİLLER
Toplantılar 35 dilde; notlar, çeviriler ve cevaplar 37 dilde, Türkçe dahil. Uygulamanın arayüzü Türkçe ve İngilizce.

GİZLİLİK
Toplantıların yapay zekâ modellerini eğitmek için kullanılmaz. Ses yalnızca transkript ve not üretmek için gönderilir; sunucularımız sesini ve notlarını saklamaz. Kayıtların iPhone'unda ne kadar kalacağını sen seçersin: 7 ile 365 gün arası. Kayda başlamadan önce odadakilere söyle.

FİYAT
İlk 3 toplantı ya da 7 gün ücretsiz, hangisi önce dolarsa (giriş gerekir; deneme toplantıları en çok 90 dakika). Sonrasında Gistsmith Pro, aylık ya da yıllık otomatik yenilenen bir aboneliktir: ayda 10 saat kayıt (adil kullanım) ve toplantı başına en çok 4 saat. Ülkendeki fiyat satın almadan önce uygulamada gösterilir. Ödeme, onayladığında Apple Hesabı'ndan alınır. Abonelik, dönem bitmeden en az 24 saat önce kapatılmazsa kendiliğinden yenilenir. Apple Hesabı ayarlarından yönetebilir ya da iptal edebilirsin.

Kullanım Koşulları: https://gistsmith.com/terms
Gizlilik Politikası: https://gistsmith.com/privacy
```

### What's New (template)

```text
Gistsmith 0.1.16 [bu güncellemenin tek cümlelik asıl faydası].

Yeni
• [Özellik]: [artık ne yapabildiğin, tek cümle].

İyileştirmeler
• [Senin için daha iyi çalışan şey].
• Hata düzeltmeleri ve kararlılık iyileştirmeleri.
```

Maintenance update:

```text
Bu güncelleme kaydı ve not yazımını daha güvenilir hale getiriyor ve birkaç hatayı düzeltiyor. Geri bildirimin için teşekkürler; bize Ayarlar › Geri bildirim gönder'den yazabilirsin.
```

---

## Finnish — `fi`

### Name

```text
Gistsmith: Kokousmuistiinpanot
```

### Subtitle

```text
Tekoäly litteroi ja tiivistää
```

### Promotional Text

```text
Laita iPhone pöydälle. Kun kokous päättyy, muistiinpano on valmis: yhteenveto, päätökset ja tehtävät. Kysy aiemmista kokouksista. 3 kokousta tai 7 päivää ilmaiseksi.
```

### Keywords

```text
muistiinpanot,muistio,palaveri,kokous,pöytäkirja,nauhuri,luento,haastattelu,puhe,tekstiksi
```

### Description

```text
Gistsmith tekee iPhonesi ympärillä käydystä keskustelusta selkeät kokousmuistiinpanot. Laita puhelin pöydälle, aloita tallennus ja jatka keskustelua. Kun kokous päättyy, muistiinpano on valmis: yhteenveto, tehdyt päätökset ja jokaisen tehtävät.

Tehty kasvokkain pidettäviin kokouksiin: kahdenkeskisiin keskusteluihin, tiimipalavereihin, asiakastapaamisiin, haastatteluihin, luentoihin ja työpajoihin. Gistsmith kuuntelee iPhonesi mikrofonilla. Se ei tallenna puheluita eikä verkkokokouksia, eikä kokoukseen kutsuta bottia.

SUOMI TOIMII TÄYSIN
Suomi on täysin tuettu: litterointi, muistiinpanot, käännökset ja vastaukset. Sovelluksen käyttöliittymä on englanniksi.

TALLENNUS
• Litterointi livenä puhuessanne, puhujat eroteltuina
• Käännös livenä muistiinpanojen kielelle, jos kokous käydään toisella kielellä
• "What did I miss?" tiivistää viimeiset minuutit, kun tallennus on vielä käynnissä
• Tallennus jatkuu taustalla, ja eteneminen näkyy lukitulla näytöllä ja Dynamic Islandissa
• Aloita sovelluksesta, Ohjauskeskuksesta, Toimintopainikkeella, widgetistä, Sirillä tai Pikakomennoilla
• Tuo ääni- ja videotallenteita Tiedostoista tai Kuvista

MUISTIINPANO ON VALMIS, KUN KOKOUS PÄÄTTYY
• Yhteenveto, päätökset ja jokainen tehtävä tekijöineen ja määräaikoineen
• Sanasto ja aiheiden kulku aikaleimoineen
• Pohjat: General, One-on-one, Client meeting, Lecture / training, Job interview tai omat ohjeesi
• Kokouksen aikana lisäämäsi muistiinpanot otetaan huomioon lopullisessa muistiinpanossa
• Muokkaa tavallisella ohjeella, kuten "lyhennä yhteenvetoa"
• Jaa PDF:nä, verkkosivuna, Markdownina, tekstinä tai SRT-tekstityksenä, tai jaa muistiinpano toisella kielellä

KYSY KOKOUKSILTASI
• Kysy mitä tahansa kaikista kokouksistasi, ja vastaus kertoo, mistä kokouksista se on peräisin
• Kirjoita "/", niin saat valmiit ohjeet, kuten Follow-up email, Prep my day ja Risks and open questions
• Ennen kokousta kooste aiemmista kokouksista samojen ihmisten kanssa: päätökset ja avoimet tehtävät

PYSY AJAN TASALLA
• Omat tehtäväsi kaikista kokouksista yhdellä listalla; lisää haluamasi Muistutuksiin
• Kalenterisi kokoukset seuraavan 12 tunnin ajalta ja halutessasi muistutus minuuttia ennen alkua
• Ihmiset: nimeä puhujat kerran ja näe jokaisen kokoukset, puheaika ja tehtävät
• Hae otsikoista, ihmisistä ja litteroinneista
• Tee siitä omasi: 7 teemaa, 5 korostusväriä, fontti ja tekstikoko

YKSI TILI MACILLE JA IPHONELLE
Yksi tili ja yksi tilaus Gistsmithille Macissa ja iPhonessa. Kukin laite säilyttää itse tallentamansa kokoukset.

KIELET
Kokoukset 35 kielellä, myös suomeksi. Muistiinpanot, käännökset ja vastaukset 37 kielellä. Käyttöliittymä on englanniksi (ja turkiksi).

TIETOSUOJA
Kokouksiasi ei käytetä tekoälymallien kouluttamiseen. Ääni lähetetään vain litterointia ja muistiinpanoa varten, eivätkä palvelimemme säilytä ääntäsi tai muistiinpanojasi. Valitset itse, kuinka kauan tallenteet säilyvät iPhonessasi: 7–365 päivää. Kerro huoneessa oleville ennen tallennusta.

HINNOITTELU
3 ensimmäistä kokousta tai 7 päivää ilmaiseksi, kumpi täyttyy ensin (vaatii kirjautumisen; kokeilukokous enintään 90 minuuttia). Sen jälkeen Gistsmith Pro on kuukausittain tai vuosittain automaattisesti uusiutuva tilaus: 10 tuntia tallennusta kuukaudessa (kohtuullinen käyttö) ja enintään 4 tuntia kokousta kohden. Maasi hinta näytetään sovelluksessa ennen ostoa. Maksu veloitetaan Apple-tililtäsi, kun vahvistat oston. Tilaus uusiutuu automaattisesti, ellet peru sitä viimeistään 24 tuntia ennen kauden päättymistä. Voit hallita tai perua tilauksen Apple-tilisi asetuksissa.

Käyttöehdot: https://gistsmith.com/terms
Tietosuojaseloste: https://gistsmith.com/privacy
```

### What's New (template)

```text
Gistsmith 0.1.16 [päivityksen tärkein hyöty yhdellä lauseella].

Uutta
• [Ominaisuus]: [mitä voit nyt tehdä, yhdellä lauseella].

Parannuksia
• [Mikä toimii nyt paremmin].
• Korjauksia ja luotettavuusparannuksia.
```

Maintenance update:

```text
Tämä päivitys tekee tallennuksesta ja muistiinpanojen kirjoittamisesta luotettavampaa ja korjaa muutaman virheen. Kiitos palautteestasi; kirjoita meille sovelluksen kohdassa Settings › Send feedback.
```
