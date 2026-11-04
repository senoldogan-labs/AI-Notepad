// Derlenmiş sitenin (dist/) arama motorlarına ve yapay zekâ asistanlarına giden çıktısını denetler: her sayfanın JSON-LD
// blokları geçerli JSON ve beklenen schema.org biçiminde mi (uygulama, teklifler, işletme, sık sorulan sorular, gezinti
// izi), `/llms.txt` ve `/llms-full.txt` ürünün temel gerçeklerini ve sayfa bağlantılarını taşıyor mu, site haritasında
// yeni sayfalar var mı. Önce `npm run build` (yayın yapılandırması) çalışmalı; `npm test` bu dosyayı `node --test` ile
// çalıştırır.
import { strict as assert } from "node:assert";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const distDir: string = fileURLToPath(new URL("../dist/", import.meta.url));
const origin: string = "https://gistsmith.com";

/** JSON-LD düğümü: türü ve diğer alanları (alan değerleri JSON'dur). */
interface JsonLdNode {
  readonly "@type": string;
  readonly [key: string]: JsonValue;
}

/** JSON değeri. */
type JsonValue = string | number | boolean | null | readonly JsonValue[] | { readonly [key: string]: JsonValue };

/** Sayfadaki JSON-LD belgesi. */
interface JsonLdDocument {
  readonly "@context": string;
  readonly "@graph": readonly JsonLdNode[];
}

/** Derlemedeki HTML dosyaları (dist/'e göre yol). */
async function htmlFiles(dir: string, prefix: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const nested: string[][] = await Promise.all(
    entries.map(async (entry): Promise<string[]> => {
      const path: string = `${prefix}${entry.name}`;
      if (entry.isDirectory()) {
        return htmlFiles(join(dir, entry.name), `${path}/`);
      }
      return entry.name.endsWith(".html") ? [path] : [];
    }),
  );
  return nested.flat();
}

/** HTML'deki JSON-LD blokları, ayrıştırılmış. Saf fonksiyondur. */
function jsonLdBlocks(html: string): JsonLdDocument[] {
  return [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((match: RegExpMatchArray): JsonLdDocument => {
    const parsed: JsonLdDocument = JSON.parse(match[1] ?? "") as JsonLdDocument;
    return parsed;
  });
}

/** Belgedeki verilen türden düğümler. Saf fonksiyondur. */
function nodesOfType(documents: readonly JsonLdDocument[], type: string): JsonLdNode[] {
  return documents.flatMap((document: JsonLdDocument): readonly JsonLdNode[] => document["@graph"]).filter((node: JsonLdNode): boolean => node["@type"] === type);
}

/** Dosyanın içeriği (dist/'e göre yol). */
function distFile(path: string): Promise<string> {
  return readFile(join(distDir, path), "utf8");
}

/** Değer dizi mi (JSON dizisi). */
function isArray(value: JsonValue | undefined): value is readonly JsonValue[] {
  return Array.isArray(value);
}

/** Değer nesne mi (dizi ya da null değil). */
function isObject(value: JsonValue | undefined): value is { readonly [key: string]: JsonValue } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Düğümün metin alanı (yoksa ya da metin değilse hata). */
function text(node: { readonly [key: string]: JsonValue }, key: string): string {
  const value: JsonValue | undefined = node[key];
  assert.equal(typeof value, "string", `${key} metin olmalı: ${JSON.stringify(node)}`);
  return value as string;
}

test("every JSON-LD block is valid schema.org JSON with a graph", async () => {
  const files: string[] = await htmlFiles(distDir, "");
  assert.ok(files.length > 10, "dist/ boş: önce npm run build");
  for (const file of files) {
    for (const document of jsonLdBlocks(await distFile(file))) {
      assert.equal(document["@context"], "https://schema.org", file);
      assert.ok(document["@graph"].length > 0, file);
      for (const node of document["@graph"]) {
        assert.equal(typeof node["@type"], "string", `${file}: @type eksik`);
      }
    }
  }
});

test("home page describes the app, its offers and the organisation", async () => {
  for (const file of ["index.html", "fi.html"]) {
    const documents: JsonLdDocument[] = jsonLdBlocks(await distFile(file));
    const [app] = nodesOfType(documents, "SoftwareApplication");
    assert.ok(app !== undefined, `${file}: SoftwareApplication yok`);
    assert.equal(app["applicationCategory"], "BusinessApplication");
    assert.match(text(app, "operatingSystem"), /^macOS 15\b/);
    assert.match(text(app, "processorRequirements"), /Apple silicon/);
    const features: JsonValue | undefined = app["featureList"];
    assert.ok(isArray(features) && features.length >= 5 && features.every((feature: JsonValue): boolean => typeof feature === "string"), `${file}: featureList`);
    const offers: JsonValue | undefined = app["offers"];
    assert.ok(isArray(offers) && offers.length === 3, `${file}: offers`);
    const prices: string[] = offers.map((offer: JsonValue): string => {
      assert.ok(isObject(offer) && offer["@type"] === "Offer" && offer["priceCurrency"] === "USD", JSON.stringify(offer));
      return text(offer, "price");
    });
    assert.deepEqual(prices, ["5.99", "49.00", "0.00"]);
    const [monthly, yearly] = offers;
    assert.ok(isObject(monthly) && isObject(monthly["priceSpecification"]) && monthly["priceSpecification"]["billingDuration"] === "P1M");
    assert.ok(isObject(yearly) && isObject(yearly["priceSpecification"]) && yearly["priceSpecification"]["billingDuration"] === "P1Y");
    const [organization] = nodesOfType(documents, "Organization");
    assert.ok(organization !== undefined && text(organization, "url") === origin && text(organization, "email").includes("@"), `${file}: Organization`);
    assert.ok(isObject(app["publisher"]) && app["publisher"]["@id"] === organization["@id"], `${file}: publisher`);
    const [faq] = nodesOfType(documents, "FAQPage");
    const questions: JsonValue | undefined = faq?.["mainEntity"];
    assert.ok(isArray(questions) && questions.length >= 3, `${file}: FAQPage`);
  }
});

test("FAQ answers in JSON-LD are the answers shown on the page", async () => {
  for (const file of ["index.html", "pricing.html", "languages.html", "integrations.html"]) {
    const html: string = await distFile(file);
    const [faq] = nodesOfType(jsonLdBlocks(html), "FAQPage");
    const questions: JsonValue | undefined = faq?.["mainEntity"];
    assert.ok(isArray(questions) && questions.length > 0, `${file}: FAQPage yok`);
    for (const question of questions) {
      assert.ok(isObject(question) && question["@type"] === "Question" && isObject(question["acceptedAnswer"]), `${file}: ${JSON.stringify(question)}`);
      const name: string = text(question, "name");
      assert.ok(html.includes(`>${escapeHtml(name)}</span>`), `${file}: soru sayfada yok: ${name}`);
    }
  }
});

test("comparison and info pages carry a breadcrumb trail ending at the page", async () => {
  const pages: readonly string[] = ["compare", "vs/granola", "vs/otter", "vs/fireflies", "vs/poffle", "languages", "integrations"];
  for (const page of pages) {
    const [breadcrumbs] = nodesOfType(jsonLdBlocks(await distFile(`${page}.html`)), "BreadcrumbList");
    const items: JsonValue | undefined = breadcrumbs?.["itemListElement"];
    assert.ok(isArray(items) && items.length >= 2, `${page}: BreadcrumbList`);
    items.forEach((item: JsonValue, index: number): void => {
      assert.ok(isObject(item) && item["@type"] === "ListItem" && item["position"] === index + 1, `${page}: ${JSON.stringify(item)}`);
    });
    const first: JsonValue | undefined = items[0];
    const last: JsonValue | undefined = items.at(-1);
    assert.ok(isObject(first) && first["item"] === `${origin}/`, `${page}: ilk basamak ana sayfa olmalı`);
    assert.ok(isObject(last) && last["item"] === `${origin}/${page}`, `${page}: son basamak sayfanın kendisi olmalı`);
  }
});

test("llms.txt states the key facts and links every public page", async () => {
  const llms: string = await distFile("llms.txt");
  assert.match(llms, /^# Gistsmith\n\n> /);
  for (const fact of ["macOS 15 or later", "Apple silicon", "$5.99", "$49", "3 meetings or 7 days", "10 hours", "4 hours", "No bot", "MCP"]) {
    assert.ok(llms.includes(fact), `llms.txt: "${fact}" yok`);
  }
  for (const path of ["/pricing", "/download", "/languages", "/integrations", "/compare", "/vs/fireflies", "/vs/poffle", "/privacy#at-a-glance", "/mcp", "/llms-full.txt"]) {
    assert.ok(llms.includes(`](${origin}${path})`), `llms.txt: ${path} bağlantısı yok`);
  }
  const full: string = await distFile("llms-full.txt");
  for (const fact of ["Turkish", "Finnish", "Deepgram", "ElevenLabs", "Anthropic", "macOS 26", "Fireflies", "Poffle", "Zapier"]) {
    assert.ok(full.includes(fact), `llms-full.txt: "${fact}" yok`);
  }
  assert.ok(full.length > llms.length * 2, "llms-full.txt llms.txt'ten çok daha ayrıntılı olmalı");
});

test("the sitemap lists the new pages", async () => {
  const sitemap: string = await distFile("sitemap.xml");
  for (const path of ["/languages", "/integrations", "/vs/fireflies", "/vs/poffle"]) {
    assert.ok(sitemap.includes(`<loc>${origin}${path}</loc>`), `sitemap.xml: ${path} yok`);
  }
});

test("the privacy page has stable data-handling anchors", async () => {
  const html: string = await distFile("privacy.html");
  for (const id of ["at-a-glance", "data-live-audio", "data-recording", "data-final-transcript", "data-ai-text", "data-on-device", "data-voice-typing"]) {
    assert.ok(html.includes(`id="${id}"`), `privacy.html: #${id} yok`);
  }
});

/** Astro'nun metin kaçışı (soru metinlerini HTML'de aramak için). Saf fonksiyondur. */
function escapeHtml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}
