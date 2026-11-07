// docs/appstore/*.md içindeki App Store metinlerini App Store Connect sınırlarına ve anahtar kelime kurallarına göre
// denetler. Her `## ` başlığı bir dil (başlıktaki `kod`, ör. `en-GB`) ya da özel ürün sayfasıdır; altındaki `### Alan` /
// `#### Alan` başlığından sonraki ilk ```text bloğu o alanın metnidir.
//
// Anahtar kelimelerde: en çok 100, en az 95 UTF-8 bayt; virgülden sonra boşluk yok; tekrar yok; aynı dilin ad ve alt
// başlığındaki sözcük yok; "free", "app", rakip ve platform adları yok. Dil kodu olan bölümlerde ayrıca: ad
// "Gistsmith" ile başlar, kod aşağıdaki mağaza tablosunda bilinir ve bir anahtar kelime, o dilin ana mağazasının
// okuduğu başka bir dilin anahtar kelimelerinde yer almaz (o mağazada zaten aranıyordur).
// Sorun varsa hepsini yazar ve 1 ile çıkar.
//
// Kullanım (repo kökünden): node scripts/appstore-screenshots/metadata-check.ts docs/appstore/metadata.md docs/appstore/custom-product-pages.md
import { readFile } from "node:fs/promises";

/** Bir metin alanı: hangi bölümde (ve dil kodu varsa hangi dilde), hangi alan, içerik. */
interface Field {
  readonly section: string;
  readonly locale: string | null;
  readonly name: string;
  readonly text: string;
}

/** Alanın sınırı: karakter sayısı ya da (anahtar kelimelerde) UTF-8 bayt sayısı. */
interface Limit {
  readonly prefix: string;
  readonly max: number;
  readonly unit: "characters" | "bytes";
}

/** Apple'ın sınırları (anahtar kelimeler en sıkı ölçüyle, bayt olarak). */
const limits: readonly Limit[] = [
  { prefix: "Name", max: 30, unit: "characters" },
  { prefix: "Subtitle", max: 30, unit: "characters" },
  { prefix: "Promotional Text", max: 170, unit: "characters" },
  { prefix: "Keywords", max: 100, unit: "bytes" },
  { prefix: "Description", max: 4000, unit: "characters" },
  { prefix: "What's New", max: 4000, unit: "characters" },
];

/** 100 baytın boşa gitmemesi için alt sınır (3 baytlık yazılarda 96–99'a denk gelir). */
const minKeywordBytes: number = 95;

/** Anahtar kelimede yeri olmayan sözcükler: Apple'ın zaten eşlediği ya da kurallarına aykırı olanlar, rakipler,
 * platformlar ve iPhone uygulamasının yapmadığı arama kayıtları. */
const bannedKeywordWords: ReadonlySet<string> = new Set<string>([
  "free", "app", "apps", "gratis", "gratuit", "gratuito", "grátis", "kostenlos", "ücretsiz", "ilmainen", "無料",
  "무료", "免费", "otter", "granola", "plaud", "fireflies", "notta", "fathom", "tactiq", "zoom", "teams", "meet",
  "call", "calls",
]);

/** Apple'ın mağaza → dil tablosu (https://developer.apple.com/help/app-store-connect/reference/app-store-localizations/,
 * 2026-11-07), yalnızca docs/appstore/metadata.md'deki dillere indirgenmiş: her mağazanın aradığı yerelleştirmeler. */
const storefrontLocales: Readonly<Record<string, readonly string[]>> = {
  "United States": ["en-US", "es-MX", "fr", "ko", "pt-BR", "zh-Hans"],
  "United Kingdom": ["en-GB"],
  Mexico: ["es-MX", "en-GB"],
  Spain: ["es-ES", "en-GB"],
  Germany: ["de", "en-GB"],
  France: ["fr", "en-GB"],
  Italy: ["it", "en-GB"],
  Brazil: ["pt-BR", "en-GB"],
  Netherlands: ["nl", "en-GB"],
  Japan: ["ja", "en-US"],
  "Republic of Korea": ["ko", "en-GB"],
  "China mainland": ["zh-Hans", "en-GB"],
  Finland: ["en-GB", "fi"],
  "Türkiye": ["en-GB", "tr"],
};

/** Her dilin ana mağazası: o dilin anahtar kelimeleri bu mağazanın okuduğu diğer dillerle çakışmamalı. */
const homeStorefront: Readonly<Record<string, string>> = {
  "en-US": "United States",
  "en-GB": "United Kingdom",
  "es-MX": "Mexico",
  "es-ES": "Spain",
  de: "Germany",
  fr: "France",
  it: "Italy",
  "pt-BR": "Brazil",
  nl: "Netherlands",
  ja: "Japan",
  ko: "Republic of Korea",
  "zh-Hans": "China mainland",
  fi: "Finland",
  tr: "Türkiye",
};

/** Bölüm başlığındaki dil kodu (`en-GB`), yoksa null. Saf fonksiyondur. */
function sectionLocale(heading: string): string | null {
  const match: RegExpMatchArray | null = heading.match(/`([a-z]{2}(?:-[A-Za-z]+)?)`/);
  return match === null ? null : (match[1] ?? null);
}

/** Markdown'dan alanları çıkarır. Saf fonksiyondur. */
export function parseFields(markdown: string): readonly Field[] {
  const fields: Field[] = [];
  let section: string = "";
  let locale: string | null = null;
  let pending: string | null = null;
  let block: string[] | null = null;
  for (const line of markdown.split("\n")) {
    if (block !== null) {
      if (line === "```") {
        if (pending !== null) {
          fields.push({ section, locale, name: pending, text: block.join("\n") });
        }
        pending = null;
        block = null;
      } else {
        block.push(line);
      }
      continue;
    }
    if (line.startsWith("## ")) {
      section = line.slice(3).trim();
      locale = sectionLocale(section);
      pending = null;
    } else if (/^#{3,4} /.test(line)) {
      pending = line.replace(/^#{3,4} /, "").trim();
    } else if (line === "```text") {
      block = [];
    }
  }
  return fields;
}

/** Bir metnin sözcükleri (küçük harf); tireli sözcük hem bütün hem parçalarıyla. Saf fonksiyondur. */
function words(text: string): readonly string[] {
  const whole: readonly string[] = text
    .toLocaleLowerCase()
    .split(/[^\p{L}\p{N}-]+/u)
    .filter((word: string) => word.length > 0);
  const parts: readonly string[] = whole.flatMap((word: string) => (word.includes("-") ? word.split("-") : []));
  return [...whole, ...parts].filter((word: string) => word.length > 0);
}

/** Anahtar kelime alanının terimleri (küçük harf). Saf fonksiyondur. */
function keywordTerms(text: string): readonly string[] {
  return text.split(",").map((term: string) => term.toLocaleLowerCase());
}

/** Bölümün ad ve alt başlık sözcükleri. Saf fonksiyondur. */
function titleWords(fields: readonly Field[], section: string): ReadonlySet<string> {
  return new Set<string>(
    fields
      .filter((field: Field) => field.section === section && (field.name === "Name" || field.name === "Subtitle"))
      .flatMap((field: Field) => words(field.text)),
  );
}

/** Alanın sorunları. Saf fonksiyondur. */
export function fieldProblems(field: Field, all: readonly Field[]): readonly string[] {
  const limit: Limit | undefined = limits.find((candidate: Limit) => field.name.startsWith(candidate.prefix));
  if (limit === undefined) {
    return [];
  }
  const problems: string[] = [];
  const size: number = limit.unit === "bytes" ? Buffer.byteLength(field.text, "utf8") : [...field.text].length;
  if (size > limit.max) {
    problems.push(`${field.section} › ${field.name}: ${size} ${limit.unit} (max ${limit.max})`);
  }
  if (limit.prefix === "Name" && field.locale !== null && !field.text.startsWith("Gistsmith")) {
    problems.push(`${field.section} › ${field.name}: must start with "Gistsmith"`);
  }
  if (limit.prefix === "Keywords") {
    if (size < minKeywordBytes) {
      problems.push(`${field.section} › ${field.name}: ${size} bytes (use at least ${minKeywordBytes} of 100)`);
    }
    if (/,\s/.test(field.text)) {
      problems.push(`${field.section} › ${field.name}: space after a comma`);
    }
    const terms: readonly string[] = keywordTerms(field.text);
    const duplicates: readonly string[] = terms.filter((term: string, index: number) => terms.indexOf(term) !== index);
    if (duplicates.length > 0) {
      problems.push(`${field.section} › ${field.name}: repeated ${duplicates.join(", ")}`);
    }
    const termWords: readonly string[] = terms.flatMap((term: string) => words(term));
    const title: ReadonlySet<string> = titleWords(all, field.section);
    const repeated: readonly string[] = termWords.filter((word: string) => title.has(word));
    if (repeated.length > 0) {
      problems.push(`${field.section} › ${field.name}: already in name/subtitle: ${repeated.join(", ")}`);
    }
    const banned: readonly string[] = termWords.filter((word: string) => bannedKeywordWords.has(word));
    if (banned.length > 0) {
      problems.push(`${field.section} › ${field.name}: not allowed: ${banned.join(", ")}`);
    }
  }
  return problems;
}

/** Dil kodlu bölümlerin mağaza sorunları: bilinmeyen dil ve ana mağazada başka bir dille çakışan anahtar kelime.
 * Saf fonksiyondur. */
export function storefrontProblems(all: readonly Field[]): readonly string[] {
  const keywords: readonly Field[] = all.filter((field: Field) => field.locale !== null && field.name === "Keywords");
  const byLocale: ReadonlyMap<string, Field> = new Map<string, Field>(
    keywords.map((field: Field) => [field.locale ?? "", field]),
  );
  return keywords.flatMap((field: Field) => {
    const locale: string = field.locale ?? "";
    const home: string | undefined = homeStorefront[locale];
    if (home === undefined) {
      return [`${field.section}: locale ${locale} has no home storefront in metadata-check.ts`];
    }
    const others: readonly string[] = (storefrontLocales[home] ?? []).filter((other: string) => other !== locale);
    const own: readonly string[] = keywordTerms(field.text);
    return others.flatMap((other: string) => {
      const otherField: Field | undefined = byLocale.get(other);
      if (otherField === undefined) {
        return [`${field.section}: ${home} also reads ${other}, which has no Keywords block`];
      }
      const theirs: ReadonlySet<string> = new Set<string>(keywordTerms(otherField.text));
      const shared: readonly string[] = own.filter((term: string) => theirs.has(term));
      return shared.length === 0
        ? []
        : [`${field.section} › Keywords: ${home} already reads ${shared.join(", ")} from ${other}`];
    });
  });
}

/** Alanın ölçüsü (rapor için). Saf fonksiyondur. */
function fieldSize(field: Field): string {
  return `${[...field.text].length} chars / ${Buffer.byteLength(field.text, "utf8")} bytes`;
}

async function main(): Promise<void> {
  const paths: readonly string[] = process.argv.slice(2);
  if (paths.length === 0) {
    throw new Error("Usage: node metadata-check.ts <file.md>…");
  }
  const problems: string[] = [];
  for (const path of paths) {
    const fields: readonly Field[] = parseFields(await readFile(path, "utf8"));
    for (const field of fields) {
      console.log(`${path} · ${field.section} › ${field.name}: ${fieldSize(field)}`);
      problems.push(...fieldProblems(field, fields));
    }
    problems.push(...storefrontProblems(fields));
  }
  if (problems.length > 0) {
    console.error(`\n${problems.length} problem(s):\n${problems.join("\n")}`);
    process.exit(1);
  }
  console.log("\nAll fields within App Store Connect limits and keyword rules.");
}

await main();
