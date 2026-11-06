// Yapay zekâ asistanları için ürün belgesi (https://llmstxt.org): `/llms.txt` kısa özet ve sayfa bağlantıları,
// `/llms-full.txt` ayrıntılı ürün belgesi. İkisi de sayfaların kullandığı aynı kaynaklardan derlemede üretilir (copy.ts
// metinleri ve fiyatları, lib/languages.ts dil listeleri, data-handling.ts veri tablosu, blog koleksiyonu); burada yalnızca
// belgenin başlıkları ve bağlayıcı cümleleri vardır, ürün gerçeği elle yazılmaz. Böylece sayfalar değişince belge de
// değişir.
import { productName } from "../config";
import type { ComparisonTopic, Copy, CompetitorCopy, Faq, IconItem, IconText, IntegrationGroupCopy, IntegrationItemCopy, McpToolCopy, TitledText } from "../copy";
import type { DataHandlingCopy, DataHandlingRow } from "../data-handling";
import type { Operator } from "../legal/operator";
import { type PageKey, pageUrl } from "../routes";
import { type AppLanguage, languageNameList } from "./languages";

/** Belgenin dayandığı metin beklenen biçimde değil: copy.ts değişti, llms.ts güncellenmeli. */
export class LlmsSourceError extends Error {
  override readonly name: string = "LlmsSourceError";
}

/** Belgede listelenen blog yazısı. */
export interface LlmsBlogPost {
  readonly title: string;
  readonly description: string;
  readonly url: string;
}

/** Belgelerin girdileri: sitenin metinleri ve verileri. */
export interface LlmsInput {
  readonly origin: string;
  readonly copy: Copy;
  readonly operator: Operator;
  readonly dataHandling: DataHandlingCopy;
  readonly spokenLanguages: readonly AppLanguage[];
  readonly noteLanguages: readonly AppLanguage[];
  readonly interfaceLanguages: readonly AppLanguage[];
  readonly blogPosts: readonly LlmsBlogPost[];
}

/** Karşılaştırma sayfaları, dizindeki sırayla. */
const competitorPages: readonly { readonly competitor: keyof Copy["compare"]["competitors"]; readonly page: PageKey }[] = [
  { competitor: "granola", page: "vsGranola" },
  { competitor: "otter", page: "vsOtter" },
  { competitor: "fireflies", page: "vsFireflies" },
  { competitor: "poffle", page: "vsPoffle" },
];

/** Markdown bağlantı satırı: `- [ad](adres): açıklama`. Saf fonksiyondur. */
function linkLine(name: string, url: string, description: string): string {
  return `- [${name}](${url}): ${description}`;
}

/** Markdown tablo hücresi: dikey çizgi ve satır sonu kaçırılır. Saf fonksiyondur. */
function cell(value: string): string {
  return value.replaceAll("|", "\\|").replaceAll("\n", " ");
}

/** Markdown tablosu. Saf fonksiyondur. */
function table(header: readonly string[], rows: readonly (readonly string[])[]): string {
  const line = (cells: readonly string[]): string => `| ${cells.map(cell).join(" | ")} |`;
  return [line(header), line(header.map((): string => "---")), ...rows.map(line)].join("\n");
}

/** Soru-yanıt listesi (Markdown). Saf fonksiyondur. */
function faqMarkdown(items: readonly Faq[]): string {
  return items.map((item: Faq): string => `### ${item.question}\n\n${item.answer}`).join("\n\n");
}

/** Dilleri "Ad (kod)" biçiminde virgülle sıralar. Saf fonksiyondur. */
function languageCodes(languages: readonly AppLanguage[]): string {
  return languages.map((language: AppLanguage): string => `${language.name} (${language.code})`).join(", ");
}

/** Belgenin başı: ad, tek cümlelik özet ve temel gerçekler (iki belgede aynı). Saf fonksiyondur. */
function header(input: LlmsInput): string {
  const { copy } = input;
  const training: IconText | undefined = copy.home.trust.items.find((item: IconText): boolean => item.icon === "sparkle");
  if (training === undefined) {
    throw new LlmsSourceError("copy.home.trust.items içinde yapay zekâ eğitimi maddesi (icon: sparkle) yok; llms.ts güncellenmeli.");
  }
  const facts: readonly string[] = [
    `Platform: ${copy.download.requirementsNote}`,
    `Price: ${copy.compare.us.price} (${copy.pricing.plans.map((plan): string => `${plan.name.toLowerCase()}: ${plan.detail.replace(/\.$/, "")}`).join("; ")}).`,
    `${copy.common.trial}.`,
    `Limits: ${copy.compare.us.limits} (fair use; the monthly hours reset on the first day of each month, UTC).`,
    `Meeting capture: ${copy.compare.us.capture}.`,
    `Languages: ${input.spokenLanguages.length} spoken languages (live and final transcript) and ${input.noteLanguages.length} languages for notes and live translation, including Turkish, Finnish and English. The app itself is available in ${input.interfaceLanguages.length} languages (${languageNameList(input.interfaceLanguages)}).`,
    `Data: ${copy.compare.us.storage}; our servers keep no audio, and no notes they can read (optional Mac–iPhone sync stores only an end-to-end encrypted copy). ${training.text}`,
    `Company: ${input.operator.name}, Finland (EU); contact ${input.operator.email}.`,
  ];
  return [`# ${productName}`, `> ${copy.home.lead}`, "Key facts:", facts.map((fact: string): string => `- ${fact}`).join("\n")].join("\n\n");
}

/** `/llms.txt`: özet ve sayfa bağlantıları (llmstxt.org biçimi). Saf fonksiyondur. */
export function llmsTxt(input: LlmsInput): string {
  const { copy, origin } = input;
  const url = (page: PageKey): string => pageUrl(page, origin);
  const sections: readonly string[] = [
    header(input),
    [
      "## Product",
      linkLine("Home", url("home"), copy.home.meta.description),
      linkLine("Pricing", url("pricing"), copy.pricing.meta.description),
      linkLine("Download", url("download"), copy.download.meta.description),
      linkLine("Languages", url("languages"), copy.languages.meta.description),
      linkLine("Integrations", url("integrations"), copy.integrations.meta.description),
      linkLine("MCP server", url("mcp"), copy.mcp.meta.description),
    ].join("\n"),
    [
      "## Comparisons",
      linkLine("Compare", url("compare"), copy.compare.meta.description),
      ...competitorPages.map((entry): string => {
        const them: CompetitorCopy = copy.compare.competitors[entry.competitor];
        return linkLine(them.title, url(entry.page), them.summary);
      }),
    ].join("\n"),
    [
      "## Privacy and terms",
      linkLine(input.dataHandling.title, `${url("privacy")}#at-a-glance`, input.dataHandling.lead),
      linkLine("Privacy policy", url("privacy"), copy.privacyMeta.description),
      linkLine("Terms of service", url("terms"), copy.termsMeta.description),
    ].join("\n"),
    [
      "## Optional",
      linkLine("Full product sheet", `${origin}/llms-full.txt`, "Everything above in detail: features, language lists, integrations, data handling, comparisons and FAQ."),
      linkLine("Blog", url("blog"), copy.blog.meta.description),
      ...input.blogPosts.map((post: LlmsBlogPost): string => linkLine(post.title, post.url, post.description)),
    ].join("\n"),
  ];
  return `${sections.join("\n\n")}\n`;
}

/** Karşılaştırma tablosu (bizim sütun ve rakipler), konular sayfadaki sırayla; doğrulanmamış değer "not checked". Saf fonksiyondur. */
function comparisonTable(copy: Copy): string {
  const topics: readonly ComparisonTopic[] = Object.keys(copy.compare.topics) as ComparisonTopic[];
  const competitors: readonly CompetitorCopy[] = competitorPages.map((entry): CompetitorCopy => copy.compare.competitors[entry.competitor]);
  return table(
    [copy.compare.topicColumn, productName, ...competitors.map((them: CompetitorCopy): string => them.name)],
    topics.map((topic: ComparisonTopic): readonly string[] => [
      copy.compare.topics[topic],
      copy.compare.us[topic],
      ...competitors.map((them: CompetitorCopy): string => them.values[topic] ?? "not checked"),
    ]),
  );
}

/** `/llms-full.txt`: ayrıntılı ürün belgesi. Saf fonksiyondur. */
export function llmsFullTxt(input: LlmsInput): string {
  const { copy, origin, dataHandling } = input;
  const url = (page: PageKey): string => pageUrl(page, origin);
  const features = copy.home.features;
  const featureSections: readonly TitledText[] = [features.live, features.tasks, features.missed, features.ask, features.followUp, features.templates, features.voiceTyping, features.screens];
  const sections: readonly string[] = [
    header(input),
    `Website: ${url("home")}. Short version: ${origin}/llms.txt.`,
    [
      "## Features",
      ...featureSections.map((feature: TitledText): string => `### ${feature.title}\n\n${feature.text}`),
      `### Everything in the plan\n\n${copy.pricing.included.map((item: IconItem): string => `- ${item.text}`).join("\n")}`,
    ].join("\n\n"),
    [
      "## Pricing and limits",
      `Source: ${url("pricing")}`,
      copy.pricing.plans.map((plan): string => `- ${plan.name}: ${plan.price} ${plan.per}. ${plan.detail}`).join("\n"),
      copy.pricing.limits.map((limit: IconText): string => `- ${limit.title}: ${limit.text}`).join("\n"),
      `${copy.pricing.taxTitle}: ${copy.pricing.taxText}`,
    ].join("\n\n"),
    [
      "## Platforms and requirements",
      `Source: ${url("download")}`,
      `- ${copy.download.requirementsNote}`,
      `- ${copy.download.installSteps.map((step: TitledText): string => `${step.title}: ${step.text}`).join(" ")}`,
    ].join("\n"),
    [
      "## Languages",
      `Source: ${url("languages")}`,
      `### ${copy.languages.spokenTitle} (${input.spokenLanguages.length})\n\n${copy.languages.spokenLead}\n\n${languageCodes(input.spokenLanguages)}.\n\nIn short: ${languageNameList(input.spokenLanguages)}.`,
      `### ${copy.languages.notesTitle} (${input.noteLanguages.length})\n\n${copy.languages.notesLead}\n\n${languageCodes(input.noteLanguages)}.`,
      `### ${copy.languages.interfaceTitle} (${input.interfaceLanguages.length})\n\n${copy.languages.interfaceLead}\n\n${languageCodes(input.interfaceLanguages)}.`,
      `### ${copy.languages.highlightsTitle}\n\n${copy.languages.highlights.map((item: TitledText): string => `- ${item.title}: ${item.text}`).join("\n")}`,
      `### ${copy.languages.mixedTitle}\n\n${copy.languages.mixed.map((item: TitledText): string => `- ${item.title}: ${item.text}`).join("\n")}`,
    ].join("\n\n"),
    [
      "## Integrations",
      `Source: ${url("integrations")}`,
      copy.integrations.lead,
      ...copy.integrations.groups.map(
        (group: IntegrationGroupCopy): string =>
          `### ${group.title}\n\n${group.lead}\n\n${group.items.map((item: IntegrationItemCopy): string => `- ${item.name}: ${item.text}`).join("\n")}`,
      ),
      `### ${copy.integrations.webhookExampleLabel}\n\n\`\`\`json\n${copy.integrations.webhookExample}\n\`\`\``,
      `### ${copy.integrations.notBuiltInTitle}\n\n${copy.integrations.notBuiltIn.map((item: string): string => `- ${item}`).join("\n")}`,
    ].join("\n\n"),
    [
      "## MCP server",
      `Source: ${url("mcp")}`,
      copy.mcp.lead,
      copy.mcp.tools.map((tool: McpToolCopy): string => `- \`${tool.name}\`: ${tool.text} Input: ${tool.input}.`).join("\n"),
    ].join("\n\n"),
    [
      `## ${dataHandling.title}`,
      `Source: ${url("privacy")}#at-a-glance (${dataHandling.lead})`,
      table(
        [dataHandling.columns.data, dataHandling.columns.where, dataHandling.columns.stored, dataHandling.columns.retention],
        dataHandling.rows.map((row: DataHandlingRow): readonly string[] => [row.data, row.where, row.stored, row.retention]),
      ),
      copy.home.trust.items.map((item: IconText): string => `- ${item.title}: ${item.text}`).join("\n"),
    ].join("\n\n"),
    [
      "## Comparison with Granola, Otter.ai, Fireflies.ai and Poffle",
      `Source: ${url("compare")}. ${copy.compare.checked} Competitor values come only from each vendor's own website (its pricing page; Poffle has none, so its home page and blog): ${competitorPages.map((entry): string => copy.compare.competitors[entry.competitor].pricingUrl).join(", ")}. "not checked" means the point wasn't part of what we checked there, not that the feature is missing.`,
      `### ${copy.compare.why.title}\n\n${copy.compare.why.items.map((item: IconText): string => `- ${item.title}: ${item.text}`).join("\n")}`,
      comparisonTable(copy),
      ...competitorPages.map((entry): string => {
        const them: CompetitorCopy = copy.compare.competitors[entry.competitor];
        return [
          `### ${them.title} (${url(entry.page)})`,
          them.lead,
          `${them.strengthsTitle}:\n${them.strengths.map((item: string): string => `- ${item}`).join("\n")}`,
          `${them.pickCompetitor.title}:\n${them.pickCompetitor.points.map((item: string): string => `- ${item}`).join("\n")}`,
          `${them.pickUs.title}:\n${them.pickUs.points.map((item: string): string => `- ${item}`).join("\n")}`,
        ].join("\n\n");
      }),
      copy.compare.trademarks,
    ].join("\n\n"),
    ["## Questions", faqMarkdown([...copy.home.faq, ...copy.pricing.faq, ...copy.languages.faq, ...copy.integrations.faq])].join("\n\n"),
    [
      "## Company",
      `${input.operator.name}, ${input.operator.legalForm}, business ID ${input.operator.businessId}, ${input.operator.address}. Contact: ${input.operator.email} or ${url("contact")}.`,
      `Privacy policy: ${url("privacy")}. Terms of service: ${url("terms")}. Blog: ${url("blog")}.`,
    ].join("\n\n"),
  ];
  return `${sections.join("\n\n")}\n`;
}
