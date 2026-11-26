import type { EmailCopy, FreePlanFacts, TrialFacts } from "./types";

export const tr: EmailCopy = {
  htmlLang: "tr",
  footer: {
    lifecycleReason: "Bunu, Gistsmith ipuçları ve hatırlatmaları istediğin için alıyorsun.",
    unsubscribe: "Abonelikten çık",
    inApp: "ya da Gistsmith › Ayarlar › Hesap'tan kapat.",
    confirmReason:
      "Biri bu adresi Gistsmith'e girdi. Sen değilsen bu e-postayı yok say: bağlantıya tıklanmadıkça başka bir şey gönderilmez ve adresi 7 gün içinde sileriz.",
    notMe: "Bu ben değilim",
    privacy: (address: string): string => `Gizlilik soruları: ${address}`,
    privacyPolicy: "Gizlilik politikası",
    country: "Finlandiya",
    reply: "Sorun varsa bu e-postayı yanıtlaman yeter.",
    linkFallback: "Düğme çalışmazsa bu bağlantıyı aç:",
  },
  confirm: {
    subject: "Gistsmith için e-postanı onayla",
    preheader: "Tek tıkla Gistsmith ipuçları ve deneme hatırlatman gelsin.",
    heading: "E-postanı onayla",
    body: [
      "Gistsmith'ten birkaç ipucu ve ücretsiz denemen bitmeden bir hatırlatma istedin.",
      "Bu adresi onaylarsan başlarız. Başka bir şey göndermeyiz; istediğin zaman durdurabilirsin.",
    ],
    cta: "E-postamı onayla",
    note: "Bağlantı 7 gün geçerli.",
  },
  welcome: {
    subject: "Gistsmith ile ilk toplantın",
    preheader: "Bir toplantıyı kaydet, bitince notun hazır olsun.",
    heading: "Gistsmith'e hoş geldin",
    body: [
      "Gistsmith'in ne yaptığını görmenin en hızlı yolu gerçek bir toplantı. Bir sonraki görüşme başlayınca Mac'te Gistsmith'te Kaydı başlat'a tıkla ya da iPhone'da Gistsmith'i açıp Kaydı başlat'a dokun.",
      "Toplantı bitince transkripti, kısa bir notu ve yapılacakları alırsın.",
      "iPhone'da Gistsmith Klavye ile her uygulamada sesle yazabilirsin. Ücretsiz: Gistsmith › Ayarlar › Klavye'den aç.",
    ],
    cta: "Toplantı kaydet",
  },
  activation: {
    subject: "İlk toplantına hazır mısın?",
    preheader: "Ücretsiz denemen ilk toplantınla başlar, öncesinde değil.",
    heading: "Denemen henüz başlamadı",
    body: (trial: TrialFacts): readonly string[] => [
      `Gistsmith'e kaydoldun ama henüz bir toplantı kaydetmedin. Sorun değil: ücretsiz denemen (${trial.meetings} toplantı ya da ${trial.days} gün) ilk toplantınla başlar.`,
      "Bir dahaki Zoom, Teams ya da Google Meet görüşmende veya yüz yüze toplantında Gistsmith'te kaydı başlat. Toplantı bitince notun hazır olur.",
      "Bu konuda gönderdiğimiz tek hatırlatma bu.",
    ],
    cta: "Toplantı kaydet",
  },
  trialEnding: {
    subject: "Gistsmith denemen yakında bitiyor",
    preheader: "Sonrasında toplantılarına ve notlarına ne olacağı.",
    heading: "Denemen yakında bitiyor",
    oneMeetingLeft: "Bir ücretsiz deneme toplantın kaldı.",
    endsWithinDay: "Ücretsiz denemen bir gün içinde bitiyor.",
    nextFree: (free: FreePlanFacts): string =>
      `Sonrasında hesabın kendiliğinden Ücretsiz plana geçer: ayda ${free.notesPerMonth} yapay zekâ notu (${free.maxMeetingMinutes} dakikaya kadar toplantılar için) ve ayda ${free.asksPerMonth} Sor cevabı.`,
    nextSubscribe: "Sonrasında Gistsmith'in toplantılarını yazıya dökmeye ve not yazmaya devam etmesi için abonelik gerekir.",
    keep: "Toplantıların ve notların her durumda cihazlarında kalır.",
    cta: "Planları gör",
  },
  freePlan: {
    subject: "Gistsmith Ücretsiz plandasın",
    preheader: "Ücretsiz planda her ay neler var.",
    heading: "Ücretsiz plana hoş geldin",
    intro: "Denemen bitti; hesabın artık Ücretsiz planda. Bu planın süresi dolmaz.",
    items: (free: FreePlanFacts): readonly string[] => [
      `Ayda ${free.notesPerMonth} yapay zekâ notu, ${free.maxMeetingMinutes} dakikaya kadar toplantılar için`,
      `Ayda ${free.asksPerMonth} Sor cevabı`,
      "Cihazında yazılan transkriptler",
      "iPhone'da Gistsmith Klavye",
    ],
    outro: "Daha uzun toplantılar ya da daha çok not gerektiğinde Kişisel ve Pro sınırları yükseltir.",
    cta: "Planları karşılaştır",
  },
};
