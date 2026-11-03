// docs/appstore/*.md içindeki App Store metinlerini App Store Connect sınırlarına göre denetler. Her `## ` başlığı bir
// dil (ya da özel ürün sayfası), altındaki `### Alan` / `#### Alan` başlığından sonraki ilk ```text bloğu o alanın
// metnidir. Anahtar kelimelerde ayrıca: virgülden sonra boşluk yok, tekrar yok, ad ve alt başlıktaki sözcük yok.
// Sınır aşılırsa sorunları yazar ve 1 ile çıkar.
//
// Kullanım (repo kökünden): node scripts/appstore-screenshots/metadata-check.ts docs/appstore/metadata.md docs/appstore/custom-product-pages.md
import { readFile } from "node:fs/promises";

/** Bir metin alanı: hangi bölümde, hangi alan, içerik. */
interface Field {
  readonly section: string;
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

/** Markdown'dan alanları çıkarır. Saf fonksiyondur. */
export function parseFields(markdown: string): readonly Field[] {
  const fields: Field[] = [];
  let section: string = "";
  let pending: string | null = null;
  let block: string[] | null = null;
  for (const line of markdown.split("\n")) {
    if (block !== null) {
      if (line === "```") {
        if (pending !== null) {
          fields.push({ section, name: pending, text: block.join("\n") });
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
      pending = null;
    } else if (/^#{3,4} /.test(line)) {
      pending = line.replace(/^#{3,4} /, "").trim();
    } else if (line === "```text") {
      block = [];
    }
  }
  return fields;
}

/** Bölümün ad ve alt başlık sözcükleri (küçük harf). Saf fonksiyondur. */
function titleWords(fields: readonly Field[], section: string): ReadonlySet<string> {
  const words: string[] = fields
    .filter((field: Field) => field.section === section && (field.name === "Name" || field.name === "Subtitle"))
    .flatMap((field: Field) => field.text.toLocaleLowerCase().split(/[^\p{L}\p{N}-]+/u));
  return new Set<string>(words.filter((word: string) => word.length > 0));
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
  if (limit.prefix === "Keywords") {
    if (/,\s/.test(field.text)) {
      problems.push(`${field.section} › ${field.name}: space after a comma`);
    }
    const terms: readonly string[] = field.text.split(",").map((term: string) => term.toLocaleLowerCase());
    const duplicates: readonly string[] = terms.filter((term: string, index: number) => terms.indexOf(term) !== index);
    if (duplicates.length > 0) {
      problems.push(`${field.section} › ${field.name}: repeated ${duplicates.join(", ")}`);
    }
    const title: ReadonlySet<string> = titleWords(all, field.section);
    const repeated: readonly string[] = terms.flatMap((term: string) => term.split(" ")).filter((word: string) => title.has(word));
    if (repeated.length > 0) {
      problems.push(`${field.section} › ${field.name}: already in name/subtitle: ${repeated.join(", ")}`);
    }
  }
  return problems;
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
  }
  if (problems.length > 0) {
    console.error(`\n${problems.length} problem(s):\n${problems.join("\n")}`);
    process.exit(1);
  }
  console.log("\nAll fields within App Store Connect limits.");
}

await main();
