// Uygulamanın dilleri: /languages sayfası, karşılaştırma tabloları ve /llms.txt bu listelerden üretilir (sayılar elle
// yazılmaz). Kaynaklar uygulamanın kendisidir; orada değişen liste burada da değişir:
// - Konuşulan dil (canlı ve nihai metin): AINotepadCore `MeetingLanguage` (Model/TranscriptTypes.swift): Deepgram Nova-3,
//   ElevenLabs Scribe ve Whisper'ın üçünün de desteklediği diller.
// - Not ve çeviri dili (notlar, canlı çeviri, "What did I miss?", Ask): AINotepadCore `ShareLanguage`
//   (Meeting/NoteTemplates.swift).
// - Arayüz dili (uygulamanın kendi menüleri ve ayarları): App `InterfaceLanguage` (App/AppSettings.swift).

/** Bir dil: kodu (uygulamadaki ham değer), İngilizce adı ve kendi adı. */
export interface AppLanguage {
  readonly code: string;
  readonly name: string;
  readonly nativeName: string;
}

/** Toplantıda konuşulabilen diller (canlı metin ve nihai metin), uygulamadaki sırayla. */
export const spokenLanguages: readonly AppLanguage[] = [
  { code: "fi", name: "Finnish", nativeName: "Suomi" },
  { code: "en", name: "English", nativeName: "English" },
  { code: "sv", name: "Swedish", nativeName: "Svenska" },
  { code: "no", name: "Norwegian", nativeName: "Norsk" },
  { code: "da", name: "Danish", nativeName: "Dansk" },
  { code: "et", name: "Estonian", nativeName: "Eesti" },
  { code: "de", name: "German", nativeName: "Deutsch" },
  { code: "nl", name: "Dutch", nativeName: "Nederlands" },
  { code: "fr", name: "French", nativeName: "Français" },
  { code: "es", name: "Spanish", nativeName: "Español" },
  { code: "pt", name: "Portuguese", nativeName: "Português" },
  { code: "it", name: "Italian", nativeName: "Italiano" },
  { code: "pl", name: "Polish", nativeName: "Polski" },
  { code: "cs", name: "Czech", nativeName: "Čeština" },
  { code: "sk", name: "Slovak", nativeName: "Slovenčina" },
  { code: "hu", name: "Hungarian", nativeName: "Magyar" },
  { code: "ro", name: "Romanian", nativeName: "Română" },
  { code: "bg", name: "Bulgarian", nativeName: "Български" },
  { code: "hr", name: "Croatian", nativeName: "Hrvatski" },
  { code: "el", name: "Greek", nativeName: "Ελληνικά" },
  { code: "lv", name: "Latvian", nativeName: "Latviešu" },
  { code: "lt", name: "Lithuanian", nativeName: "Lietuvių" },
  { code: "ru", name: "Russian", nativeName: "Русский" },
  { code: "uk", name: "Ukrainian", nativeName: "Українська" },
  { code: "tr", name: "Turkish", nativeName: "Türkçe" },
  { code: "ar", name: "Arabic", nativeName: "العربية" },
  { code: "he", name: "Hebrew", nativeName: "עברית" },
  { code: "fa", name: "Persian", nativeName: "فارسی" },
  { code: "hi", name: "Hindi", nativeName: "हिन्दी" },
  { code: "zh", name: "Chinese", nativeName: "中文" },
  { code: "ja", name: "Japanese", nativeName: "日本語" },
  { code: "ko", name: "Korean", nativeName: "한국어" },
  { code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia" },
  { code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt" },
  { code: "th", name: "Thai", nativeName: "ไทย" },
];

/** Notların, canlı çevirinin, "What did I miss?" özetinin ve Ask yanıtlarının yazılabildiği diller (tek ayar). */
export const noteLanguages: readonly AppLanguage[] = [
  { code: "fi", name: "Finnish", nativeName: "Suomi" },
  { code: "en", name: "English", nativeName: "English" },
  { code: "sv", name: "Swedish", nativeName: "Svenska" },
  { code: "nb", name: "Norwegian (Bokmål)", nativeName: "Norsk" },
  { code: "da", name: "Danish", nativeName: "Dansk" },
  { code: "et", name: "Estonian", nativeName: "Eesti" },
  { code: "de", name: "German", nativeName: "Deutsch" },
  { code: "nl", name: "Dutch", nativeName: "Nederlands" },
  { code: "fr", name: "French", nativeName: "Français" },
  { code: "es", name: "Spanish", nativeName: "Español" },
  { code: "pt", name: "Portuguese", nativeName: "Português" },
  { code: "it", name: "Italian", nativeName: "Italiano" },
  { code: "pl", name: "Polish", nativeName: "Polski" },
  { code: "cs", name: "Czech", nativeName: "Čeština" },
  { code: "sk", name: "Slovak", nativeName: "Slovenčina" },
  { code: "hu", name: "Hungarian", nativeName: "Magyar" },
  { code: "ro", name: "Romanian", nativeName: "Română" },
  { code: "bg", name: "Bulgarian", nativeName: "Български" },
  { code: "hr", name: "Croatian", nativeName: "Hrvatski" },
  { code: "el", name: "Greek", nativeName: "Ελληνικά" },
  { code: "lv", name: "Latvian", nativeName: "Latviešu" },
  { code: "lt", name: "Lithuanian", nativeName: "Lietuvių" },
  { code: "ru", name: "Russian", nativeName: "Русский" },
  { code: "uk", name: "Ukrainian", nativeName: "Українська" },
  { code: "tr", name: "Turkish", nativeName: "Türkçe" },
  { code: "az", name: "Azerbaijani", nativeName: "Azərbaycan" },
  { code: "ar", name: "Arabic", nativeName: "العربية" },
  { code: "he", name: "Hebrew", nativeName: "עברית" },
  { code: "fa", name: "Persian", nativeName: "فارسی" },
  { code: "hi", name: "Hindi", nativeName: "हिन्दी" },
  { code: "zh-Hans", name: "Chinese (Simplified)", nativeName: "简体中文" },
  { code: "zh-Hant", name: "Chinese (Traditional)", nativeName: "繁體中文" },
  { code: "ja", name: "Japanese", nativeName: "日本語" },
  { code: "ko", name: "Korean", nativeName: "한국어" },
  { code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia" },
  { code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt" },
  { code: "th", name: "Thai", nativeName: "ไทย" },
];

/**
 * Uygulamanın kendi arayüzünün (menüler, ayarlar, iletiler) dilleri: App `InterfaceLanguage` (App/AppSettings.swift),
 * katalog App/Localizable.xcstrings. Konuşulan ve not dillerinden ayrıdır.
 */
export const interfaceLanguages: readonly AppLanguage[] = [
  { code: "en", name: "English", nativeName: "English" },
  { code: "tr", name: "Turkish", nativeName: "Türkçe" },
  { code: "de", name: "German", nativeName: "Deutsch" },
  { code: "fr", name: "French", nativeName: "Français" },
  { code: "es", name: "Spanish", nativeName: "Español" },
  { code: "it", name: "Italian", nativeName: "Italiano" },
  { code: "pt-BR", name: "Portuguese (Brazil)", nativeName: "Português (Brasil)" },
  { code: "nl", name: "Dutch", nativeName: "Nederlands" },
  { code: "ja", name: "Japanese", nativeName: "日本語" },
  { code: "ko", name: "Korean", nativeName: "한국어" },
  { code: "zh-Hans", name: "Chinese (Simplified)", nativeName: "简体中文" },
  { code: "fi", name: "Finnish", nativeName: "Suomi" },
];

/** Dil adlarını İngilizce listeye çevirir ("A, B and C"). Saf fonksiyondur. */
export function languageNameList(languages: readonly AppLanguage[]): string {
  const names: readonly string[] = languages.map((language: AppLanguage): string => language.name);
  const last: string | undefined = names.at(-1);
  return names.length < 2 || last === undefined ? names.join("") : `${names.slice(0, -1).join(", ")} and ${last}`;
}
