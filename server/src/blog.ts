import { z } from "zod";
import type { BlogConfig } from "./config";
import { base64Decode, base64Encode, decodeUtf8Strict, utf8 } from "./crypto";
import { ApiError, ProviderApiError, UpstreamError } from "./errors";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { withRetries } from "./retry";
import { isRetryableUpstreamError, isTimeoutError } from "./upstream";

/**
 * Yönetim panelinden blog yayını. Yazılar sitenin içerik koleksiyonudur (`web/src/content.config.ts`): GitHub
 * deposundaki `web/src/content/blog/<kısa ad>.md` dosyaları. Panelin her yazımı (kayıt, görsel, silme) varsayılan dala
 * doğrudan değil, yazının pull request'ine gider: ilk yazım `blog/<kısa ad>-<UTC zaman damgası>` dalını açar, commit'i
 * oraya yazar (GraphQL `createCommitOnBranch`), pull request açar ve otomatik birleştirmeyi (squash) etkinleştirir; deponun
 * zorunlu denetimleri geçince GitHub birleştirir (bkz. "Pull requests" bölümü). Liste tek GraphQL isteğiyle okunur (yazı
 * başına ayrı istek Worker'ın alt istek sınırına takılırdı), açık pull request'lerin sürümleri ikinci bir istekle üstüne
 * konur. Site her gün 06:00 UTC'de ve varsayılan dala her gönderimde yeniden derlenir (`.github/workflows/deploy-web.yml`);
 * taslaklar ve tarihi gelmemiş yazılar derlemede yayımlanmaz.
 *
 * Alan kuralları içerik şemasıyla aynıdır (başlık 10–90, açıklama 50–170, yazar boş değil, tarih `YYYY-MM-DD`, isteğe
 * bağlı `updated` `published`'dan önce olmayan bir gün, isteğe bağlı `cover` film ailelerinden biri, taslak mantıksal);
 * ayrıca tek satırlık alanlarda denetim karakteri olamaz (ön bilgi YAML'ı güvenle yazılsın diye).
 *
 * Yazının görselleri `web/public/blog/<kısa ad>/<ad>.webp` dosyalarıdır (panel tarayıcıda WebP'ye çevirip yükler, site
 * `/blog/<kısa ad>/<ad>.webp` adresinden sunar). Yazı silinince klasörü de aynı commit'te silinir.
 */

/** Yazıların depodaki klasörü. */
export const blogDirectory: string = "web/src/content/blog";

/** Yazı görsellerinin depodaki kök klasörü (`<kök>/<kısa ad>/<ad>.webp`; sitede `/blog/<kısa ad>/<ad>.webp`). */
export const blogImageDirectory: string = "web/public/blog";

/**
 * Kapak renk aileleri: sitenin film gradyanı aileleri (`web/src/lib/film.ts` `filmPalettes`; eşleşmeyi blog testi
 * denetler).
 */
export const blogCoverPalettes = ["sunset", "coral", "ocean", "mint", "rose", "violet"] as const;

/** Kapak renk ailesi. */
export type BlogCoverPalette = (typeof blogCoverPalettes)[number];

/** Yazının durumu: taslak, tarihi gelecekte (zamanlanmış) ya da yayında (tarihi bugün ya da geçmişte, UTC). */
export type BlogPostStatus = "draft" | "scheduled" | "live";

/**
 * Yazının ön bilgisi (`published`, `updated`: `YYYY-MM-DD`). `updated` ve `cover` dosyada isteğe bağlıdır; yazılmamışsa
 * null (kapak kısa addan seçilir).
 */
export interface BlogFrontMatter {
  readonly title: string;
  readonly description: string;
  readonly author: string;
  readonly published: string;
  readonly updated: string | null;
  readonly cover: BlogCoverPalette | null;
  readonly draft: boolean;
}

/**
 * Listedeki yazı: ön bilgi, kısa ad, durum ve dosyanın GitHub sürümü (`sha`; güncelleme ve silme bunu ister). Yazının
 * açık bir panel pull request'i varsa ön bilgi ve sürüm o pull request'in dalındandır ve `change` onu taşır; yoksa null.
 */
export interface BlogPostSummary extends BlogFrontMatter {
  readonly slug: string;
  readonly status: BlogPostStatus;
  readonly sha: string;
  readonly change: BlogChange | null;
}

/** Yazının tamamı: Markdown gövdesi de. */
export interface BlogPost extends BlogPostSummary {
  readonly body: string;
}

/** Jetonu girilmiş blog yapılandırması (`requireBlog`). */
export interface ActiveBlog {
  readonly owner: string;
  readonly repo: string;
  readonly branch: string;
  readonly token: string;
}

/** Kısa ad: küçük harf, rakam ve tek tirelerle ayrılmış parçalar; en çok 80 karakter. */
export const blogSlugPattern: RegExp = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const blogSlugMaxLength: number = 80;
/** Gövdenin en çok karakter sayısı. */
export const blogBodyMaxLength: number = 60_000;
/** `PUT` isteğinin en büyük gövdesi (bayt): 60 000 karakterlik gövde UTF-8 ve JSON kaçışıyla birlikte sığar. */
export const blogRequestMaxBytes: number = 512 * 1024;

/** Tek satırlık alanlarda yasak: denetim karakterleri (C0, DEL, C1) ve eşi olmayan vekil karakterler. */
const lineForbidden: RegExp = /[\u0000-\u001f\u007f-\u009f\ud800-\udfff]/u;
/** Gövdede yasak: sekme ve satır sonu dışındaki denetim karakterleri, `\r` ve eşi olmayan vekil karakterler. */
const bodyForbidden: RegExp = /[\u0000-\u0008\u000b-\u001f\u007f\ud800-\udfff]/u;
const datePattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;
const shaPattern: RegExp = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;

/** `YYYY-MM-DD` gerçek bir takvim günü mü. Saf fonksiyondur. */
function isCalendarDay(value: string): boolean {
  if (!datePattern.test(value)) {
    return false;
  }
  const parsed: Date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

/** Tek satırlık metin mi (denetim karakteri yok). Saf fonksiyondur. */
function isSingleLine(value: string): boolean {
  return !lineForbidden.test(value);
}

/** Ön bilgi alanları (içerik şemasıyla aynı kurallar). */
const frontMatterShape = {
  title: z.string().min(10).max(90).refine(isSingleLine, { message: "denetim karakteri" }),
  description: z.string().min(50).max(170).refine(isSingleLine, { message: "denetim karakteri" }),
  author: z.string().min(1).refine(isSingleLine, { message: "denetim karakteri" }),
  published: z.string().refine(isCalendarDay, { message: "YYYY-MM-DD olmalı" }),
  updated: z.string().refine(isCalendarDay, { message: "YYYY-MM-DD olmalı" }).nullable(),
  cover: z.enum(blogCoverPalettes).nullable(),
  draft: z.boolean(),
};

/** `updated` yazılmışsa `published`'dan önce olamaz. Saf fonksiyondur. */
function isUpdatedAfterPublished(value: { readonly published: string; readonly updated: string | null }): boolean {
  return value.updated === null || value.updated >= value.published;
}

const updatedRule = { message: "published'dan önce", path: ["updated"] };

const frontMatterSchema = z.strictObject(frontMatterShape).refine(isUpdatedAfterPublished, updatedRule);

/**
 * `PUT /v1/admin/blog/posts/{kısa ad}` gövdesi: `updated` ve `cover` her istekte açıkça yazılır (yoksa null); `sha` yeni
 * yazıda null, güncellemede panelin bildiği son sürüm.
 */
export const blogPostInputSchema = z
  .strictObject({
    ...frontMatterShape,
    body: z
      .string()
      .max(blogBodyMaxLength)
      .refine((value: string): boolean => value.trim().length > 0, { message: "boş" })
      .refine((value: string): boolean => !bodyForbidden.test(value), { message: "denetim karakteri" }),
    sha: z.string().regex(shaPattern).nullable(),
  })
  .refine(isUpdatedAfterPublished, updatedRule);

/** Kayıt isteği. */
export type BlogPostInput = z.output<typeof blogPostInputSchema>;

/** Yoldaki kısa adı doğrular; geçersizse `bad_request`. Saf fonksiyondur. */
export function parseBlogSlug(value: string): string {
  if (value.length > blogSlugMaxLength || !blogSlugPattern.test(value)) {
    throw new ApiError("bad_request", "The slug must contain only lowercase letters, digits and hyphens (at most 80 characters).");
  }
  return value;
}

/** Silme isteğinin `?sha=` değeri; yoksa ya da biçimi yanlışsa `bad_request`. Saf fonksiyondur. */
export function parseBlogSha(url: URL): string {
  const sha: string | null = url.searchParams.get("sha");
  if (sha === null || !shaPattern.test(sha)) {
    throw new ApiError("bad_request", "The sha query parameter (the last known version of the file) is required.");
  }
  return sha;
}

/** Jeton girilmişse etkin yapılandırma; girilmemişse `blog_unavailable`. Saf fonksiyondur. */
export function requireBlog(blog: BlogConfig): ActiveBlog {
  if (blog.token === null) {
    throw new ApiError("blog_unavailable", "Blog publishing is off: GITHUB_BLOG_TOKEN is not set on the server.");
  }
  return { owner: blog.owner, repo: blog.repo, branch: blog.branch, token: blog.token };
}

/** Yazının durumu (`today`: UTC günü, `YYYY-MM-DD`). Saf fonksiyondur. */
export function blogPostStatus(draft: boolean, published: string, today: string): BlogPostStatus {
  if (draft) {
    return "draft";
  }
  return published > today ? "scheduled" : "live";
}

/** Gövdenin dosyadaki biçimi: baştaki boş satırlar ve sondaki boşluklar atılır. Saf fonksiyondur. */
export function normalizedBlogBody(body: string): string {
  return body.replace(/^\n+/, "").trimEnd();
}

/**
 * Yazının dosya içeriği: sabit sıralı ön bilgi (metinler JSON kaçışlı çift tırnak içinde: YAML 1.2'de geçerli ve
 * her değer için güvenli; tarihler, kapak ve taslak düz; `updated` ve `cover` yalnızca doluysa), boş satır, gövde ve tek
 * satır sonu. Saf fonksiyondur.
 */
export function serializeBlogPost(frontMatter: BlogFrontMatter, body: string): string {
  return [
    "---",
    `title: ${JSON.stringify(frontMatter.title)}`,
    `description: ${JSON.stringify(frontMatter.description)}`,
    `author: ${JSON.stringify(frontMatter.author)}`,
    `published: ${frontMatter.published}`,
    ...(frontMatter.updated === null ? [] : [`updated: ${frontMatter.updated}`]),
    ...(frontMatter.cover === null ? [] : [`cover: ${frontMatter.cover}`]),
    `draft: ${String(frontMatter.draft)}`,
    "---",
    "",
    normalizedBlogBody(body),
    "",
  ].join("\n");
}

/** Okunan dosyanın ön bilgisi ve gövdesi. */
export interface ParsedBlogFile {
  readonly frontMatter: BlogFrontMatter;
  readonly body: string;
}

/** YAML'ın metin dışı bir değere çevirdiği düz değerler (boş, mantıksal, sayı, tarih). */
const nonStringPlain: RegExp = /^(?:~|null|Null|NULL|true|True|TRUE|false|False|FALSE|[-+]?(?:\d[\d_]*)?\.?\d+(?:[eE][-+]?\d+)?|0x[0-9a-fA-F]+|0o[0-7]+|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN)|\d{4}-\d{2}-\d{2}(?:[Tt ].*)?)$/;

/**
 * Ön bilgideki bir değerin metni: çift tırnaklı (JSON kaçışlı), tek tırnaklı (`''` kaçışlı) ya da düz. Düz değer YAML
 * işaretiyle başlıyor, `: ` ya da ` #` içeriyorsa okunamaz: null. Saf fonksiyondur.
 */
function scalarText(raw: string): string | null {
  if (raw.startsWith('"')) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return null;
    }
    return typeof parsed === "string" ? parsed : null;
  }
  if (raw.startsWith("'")) {
    const inner: string = raw.slice(1, -1);
    const valid: boolean = raw.length >= 2 && raw.endsWith("'") && !inner.replaceAll("''", "").includes("'");
    return valid ? inner.replaceAll("''", "'") : null;
  }
  const plain: boolean =
    raw.length > 0 && !/^[[\]{}&*!|>%@`#,]/.test(raw) && !/^[?:-](?:\s|$)/.test(raw) && !raw.includes(": ") && !raw.includes(" #") && !raw.endsWith(":");
  return plain ? raw : null;
}

/** Ön bilgideki metin alanı: düz değer YAML'da metin olmalı (ör. `true` ya da `2026` değil). Saf fonksiyondur. */
function stringValue(raw: string): string | null {
  if (!raw.startsWith('"') && !raw.startsWith("'") && nonStringPlain.test(raw)) {
    return null;
  }
  return scalarText(raw);
}

/** Dosya okunamadı: kısa adı ve sorunu taşıyan `blog_post_invalid`. Saf fonksiyondur. */
function invalidFile(slug: string, problem: string): ApiError {
  return new ApiError("blog_post_invalid", `${blogDirectory}/${slug}.md: ${problem}`);
}

/**
 * İsteğe bağlı alanın değeri: yazılmamışsa null. Yazılmış ama okunamıyorsa boş metin döner ki şema onu reddetsin
 * (geçersiz değer yok sayılıp sessizce silinmesin). Saf fonksiyondur.
 */
function optionalScalar(values: ReadonlyMap<string, string>, key: "updated" | "cover"): string | null {
  const raw: string | undefined = values.get(key);
  return raw === undefined ? null : (scalarText(raw) ?? "");
}

/**
 * Yazı dosyasını okur. Ön bilgi `---` satırlarıyla çevrili, satır başına `alan: değer` olmalı; yalnızca `title`,
 * `description`, `author`, `published`, `updated`, `cover`, `draft` alanları (her biri bir kez; `updated` ve `cover`
 * isteğe bağlı) kabul edilir: bilinmeyen alan kayıtta sessizce kaybolmasın diye reddedilir. Alanlar
 * `blogPostInputSchema` kurallarına uymalı, gövde boş olmamalı. Okunamayan dosya `blog_post_invalid`. Saf fonksiyondur.
 */
export function parseBlogFile(slug: string, text: string): ParsedBlogFile {
  if (!text.startsWith("---\n")) {
    throw invalidFile(slug, "front matter does not start with `---`");
  }
  const end: number = text.indexOf("\n---\n", 3);
  if (end < 0) {
    throw invalidFile(slug, "front matter has no closing `---` line");
  }
  const values: Map<string, string> = new Map();
  for (const line of text.slice(4, end + 1).split("\n")) {
    if (line.trim() === "") {
      continue;
    }
    const match: RegExpExecArray | null = /^([A-Za-z]+):(?: +(.*?))? *$/.exec(line);
    const key: string | undefined = match?.[1];
    if (key === undefined || !Object.hasOwn(frontMatterShape, key)) {
      throw invalidFile(slug, `unsupported front matter line: ${line.slice(0, 60)}`);
    }
    if (values.has(key)) {
      throw invalidFile(slug, `${key} appears twice`);
    }
    values.set(key, match?.[2] ?? "");
  }
  const raw = (key: keyof BlogFrontMatter): string => values.get(key) ?? "";
  const draftRaw: string = raw("draft");
  const candidate = {
    title: stringValue(raw("title")),
    description: stringValue(raw("description")),
    author: stringValue(raw("author")),
    published: scalarText(raw("published")),
    updated: optionalScalar(values, "updated"),
    cover: optionalScalar(values, "cover"),
    draft: draftRaw === "true" ? true : draftRaw === "false" ? false : null,
  };
  const parsed = frontMatterSchema.safeParse(candidate);
  if (!parsed.success) {
    const fields: string = [...new Set(parsed.error.issues.map((issue: z.core.$ZodIssue): string => issue.path.join(".")))].join(", ");
    throw invalidFile(slug, `invalid fields: ${fields}`);
  }
  const body: string = normalizedBlogBody(text.slice(end + 5));
  if (body === "") {
    throw invalidFile(slug, "body is empty");
  }
  return { frontMatter: parsed.data, body };
}

/** GitHub REST and GraphQL base address. */
const githubApi: string = "https://api.github.com";
/** Retries: 408, 429, 5xx, network errors and timeouts are tried 3 times with a warning per attempt. */
const githubAttempts: number = 3;
const githubTimeoutMs: number = 10_000;

/** GitHub reply: status and body text. */
interface GithubReply {
  readonly status: number;
  readonly text: string;
}

/** Retryable GitHub status. Not 409/422 (conflicts, validation) and not 403 (permission or secondary rate limit). Pure. */
function isRetryableGithubStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

/** Statuses returned to the caller instead of thrown: their meaning depends on the operation. */
const passedGithubStatuses: ReadonlySet<number> = new Set([404, 409, 422]);

/** Repository path of a post file. Pure. */
function postPath(slug: string): string {
  return `${blogDirectory}/${slug}.md`;
}

/** Repository path of a post's image folder. Pure. */
function imageFolderPath(slug: string): string {
  return `${blogImageDirectory}/${slug}`;
}

/** REST address under the repository. Pure. */
function repoUrl(blog: ActiveBlog, suffix: string): string {
  return `${githubApi}/repos/${blog.owner}/${blog.repo}/${suffix}`;
}

/**
 * Sends a GitHub request. 2xx, 404, 409 and 422 come back as replies (the caller decides what they mean); any other
 * status logs GitHub's error body (never the token) as `github_request_failed` and throws `UpstreamError`. 408, 429,
 * 5xx, network errors and timeouts are retried `githubAttempts` times with an `upstream_retry` warning per attempt.
 */
async function githubRequest(platform: Platform, blog: ActiveBlog, operation: string, method: string, url: string, body: object | null): Promise<GithubReply> {
  return withRetries(
    { service: "github", attempts: githubAttempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError, recordRetry: platform.recordRetry },
    async (): Promise<GithubReply> => {
      const headers: Record<string, string> = {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${blog.token}`,
        "user-agent": "gistsmith-admin-blog",
        "x-github-api-version": "2022-11-28",
      };
      if (body !== null) {
        headers["content-type"] = "application/json";
      }
      const response: Response = await platform.fetch(url, {
        method,
        headers,
        body: body === null ? null : JSON.stringify(body),
        signal: AbortSignal.timeout(githubTimeoutMs),
      });
      const text: string = await response.text();
      if (response.ok || passedGithubStatuses.has(response.status)) {
        return { status: response.status, text };
      }
      const reason: string = text.slice(0, 300);
      log("warn", "github_request_failed", { operation, method, status: response.status, reason });
      throw new UpstreamError("github", response.status, isRetryableGithubStatus(response.status), reason);
    },
  );
}

/**
 * Turns the error left after `githubRequest`'s attempts into a client error: a GitHub refusal (401, 403…) is
 * `upstream_rejected` (with the status), a transient error, network error or timeout `upstream_unavailable`.
 */
async function github(platform: Platform, blog: ActiveBlog, operation: string, method: string, url: string, body: object | null): Promise<GithubReply> {
  try {
    return await githubRequest(platform, blog, operation, method, url, body);
  } catch (error: unknown) {
    if (error instanceof UpstreamError) {
      throw error.retryable
        ? new ProviderApiError("github", "upstream_unavailable", `GitHub is not responding right now (status ${error.status}); try again shortly.`)
        : new ProviderApiError(
            "github",
            "upstream_rejected",
            `GitHub rejected the request (status ${error.status}); check that the token has Contents and Pull requests read and write access to this repository.`,
          );
    }
    if (error instanceof TypeError || isTimeoutError(error)) {
      log("warn", "github_unreachable", { operation, method, error: errorName(error) });
      throw new ProviderApiError("github", "upstream_unavailable", "Could not reach GitHub; try again shortly.");
    }
    throw error;
  }
}

/** The GitHub reply is not in the expected shape: the start of the body is logged as a warning, `upstream_unavailable`. */
function invalidGithubResponse(reply: GithubReply, operation: string, problem: string): ProviderApiError {
  log("warn", "github_response_invalid", { operation, status: reply.status, problem, body: reply.text.slice(0, 300) });
  return new ProviderApiError("github", "upstream_unavailable", "The GitHub response is not in the expected format.");
}

/** Reads a GitHub reply as JSON with a schema; otherwise `invalidGithubResponse`. */
function githubJson<Schema extends z.ZodType>(schema: Schema, reply: GithubReply, operation: string): z.output<Schema> {
  let raw: unknown;
  try {
    raw = JSON.parse(reply.text);
  } catch (error: unknown) {
    throw invalidGithubResponse(reply, operation, errorName(error));
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    throw invalidGithubResponse(reply, operation, parsed.error.issues.map((issue: z.core.$ZodIssue): string => issue.path.join(".")).join(","));
  }
  return parsed.data;
}

/** Unexpected GitHub status (e.g. 404 on a write: repository or branch missing): logged as a warning, `upstream_rejected`. */
function unexpectedGithubStatus(reply: GithubReply, operation: string): ProviderApiError {
  log("warn", "github_request_failed", { operation, status: reply.status, reason: reply.text.slice(0, 300) });
  return new ProviderApiError("github", "upstream_rejected", `GitHub returned an unexpected response (status ${reply.status}); check GITHUB_BLOG_REPO and GITHUB_BLOG_BRANCH.`);
}

/** A GraphQL error entry. */
const graphqlErrorSchema = z.object({ type: z.string().optional(), message: z.string() });

/** A GraphQL error entry (parsed). */
type GraphqlError = z.output<typeof graphqlErrorSchema>;

/** GraphQL envelope around a `data` schema. Pure. */
function graphqlEnvelope<Data extends z.ZodType>(data: Data) {
  return z.object({ data: data.nullable().optional(), errors: z.array(graphqlErrorSchema).optional() });
}

/** GraphQL error: types and the first message are logged as a warning, `upstream_rejected`. */
function graphqlRejected(operation: string, errors: readonly GraphqlError[]): ProviderApiError {
  log("warn", "github_graphql_failed", { operation, types: errors.map((error): string => error.type ?? "unknown").join(","), reason: (errors[0]?.message ?? "").slice(0, 200) });
  return new ProviderApiError("github", "upstream_rejected", "GitHub rejected the request; check the token's permissions and GITHUB_BLOG_REPO.");
}

/** Parsed GraphQL reply: `data` (null when GitHub returned none) and the error list (empty when there was none). */
interface GraphqlReply<Data> {
  readonly data: Data | null;
  readonly errors: readonly GraphqlError[];
}

/** Sends a GraphQL request and parses the envelope; errors are returned, not thrown (the caller decides). */
async function graphqlReply<Data extends z.ZodType>(
  platform: Platform,
  blog: ActiveBlog,
  operation: string,
  query: string,
  variables: Readonly<Record<string, unknown>>,
  data: Data,
): Promise<GraphqlReply<z.output<Data>>> {
  const reply: GithubReply = await github(platform, blog, operation, "POST", `${githubApi}/graphql`, { query, variables });
  if (reply.status !== 200) {
    throw unexpectedGithubStatus(reply, operation);
  }
  const envelope = githubJson(graphqlEnvelope(data), reply, operation);
  return { data: envelope.data ?? null, errors: envelope.errors ?? [] };
}

/** Sends a GraphQL request; any GraphQL error is `graphqlRejected`, a missing `data` `invalidGithubResponse`. */
async function graphqlData<Data extends z.ZodType>(
  platform: Platform,
  blog: ActiveBlog,
  operation: string,
  query: string,
  variables: Readonly<Record<string, unknown>>,
  data: Data,
): Promise<z.output<Data>> {
  const result: GraphqlReply<z.output<Data>> = await graphqlReply(platform, blog, operation, query, variables, data);
  if (result.errors.length > 0) {
    throw graphqlRejected(operation, result.errors);
  }
  if (result.data === null) {
    throw invalidGithubResponse({ status: 200, text: "" }, operation, "data is empty");
  }
  return result.data;
}

// MARK: Pull requests

/**
 * Every write from the panel goes through a pull request: the first write for a post creates the branch
 * `blog/<slug>-<UTC timestamp>` from `GITHUB_BLOG_BRANCH`, commits there, opens a pull request and enables auto-merge
 * (squash), so the repository's required checks gate the change before it reaches the default branch (and the site,
 * through `deploy-web.yml`). Later writes for the same post (another save, an image) commit to the same open pull
 * request. The pull requests themselves are the record: an open one is found by its branch name, so a pull request
 * merged or closed on GitHub is never out of sync with a copy kept elsewhere.
 */

/** Branch prefix of panel pull requests. */
export const blogBranchPrefix: string = "blog/";

/**
 * `blog/<slug>-<YYYYMMDDHHMMSS>`: the timestamp is always the last part (anchored at the end), so a slug that itself ends
 * in digits still splits correctly.
 */
const blogBranchPattern: RegExp = /^blog\/([a-z0-9]+(?:-[a-z0-9]+)*)-(\d{14})$/;

/** Pull request state as the panel shows it. */
export type BlogChangeState = "open" | "merged" | "closed";

/** Combined state of the pull request's checks (`statusCheckRollup`); `none` before any check has reported. */
export type BlogChecksState = "pending" | "passing" | "failing" | "none";

/** A panel pull request as the admin panel sees it. */
export interface BlogChange {
  readonly number: number;
  readonly url: string;
  readonly slug: string;
  readonly title: string;
  readonly state: BlogChangeState;
  /** Auto-merge is enabled (GitHub merges once the required checks pass). */
  readonly autoMerge: boolean;
  readonly checks: BlogChecksState;
  /** Last update (ISO 8601). */
  readonly updatedAt: string;
}

/** A panel pull request with what the server needs to write to it. */
interface BlogPullRequest extends BlogChange {
  /** GraphQL node id (auto-merge). */
  readonly id: string;
  readonly branch: string;
  readonly headOid: string;
}

/** Result of a write: the pull request it landed in and, when enabling auto-merge failed, GitHub's reason. */
export interface BlogWriteResult {
  readonly change: BlogChange;
  readonly autoMergeError: string | null;
}

/** Branch name of a new panel pull request. Pure. */
export function blogBranchName(slug: string, now: Date): string {
  const stamp: string = now.toISOString().replace(/\.\d{3}Z$/, "").replace(/[-:T]/g, "");
  return `${blogBranchPrefix}${slug}-${stamp}`;
}

/** Slug of a panel branch; another branch gives null. Pure. */
export function blogBranchSlug(branch: string): string | null {
  const match: RegExpExecArray | null = blogBranchPattern.exec(branch);
  const slug: string | undefined = match?.[1];
  return slug !== undefined && slug.length <= blogSlugMaxLength ? slug : null;
}

/** Checks state from GitHub's `StatusState`. Pure. */
export function blogChecksState(rollup: string | null): BlogChecksState {
  switch (rollup) {
    case "SUCCESS":
      return "passing";
    case "FAILURE":
    case "ERROR":
      return "failing";
    case "PENDING":
    case "EXPECTED":
      return "pending";
    default:
      return "none";
  }
}

const pullRequestFields: string = `id number url title state headRefName headRefOid updatedAt
  headRepository { nameWithOwner }
  autoMergeRequest { enabledAt }
  statusCheckRollup { state }`;

const pullRequestNodeSchema = z.object({
  id: z.string().min(1),
  number: z.number().int().positive(),
  url: z.string().url(),
  title: z.string(),
  state: z.enum(["OPEN", "CLOSED", "MERGED"]),
  headRefName: z.string(),
  headRefOid: z.string().regex(shaPattern),
  updatedAt: z.string(),
  headRepository: z.object({ nameWithOwner: z.string() }).nullable(),
  autoMergeRequest: z.object({ enabledAt: z.string().nullable() }).nullable(),
  statusCheckRollup: z.object({ state: z.string() }).nullable(),
});

type PullRequestNode = z.output<typeof pullRequestNodeSchema>;

const pullRequestConnectionSchema = z.object({ nodes: z.array(pullRequestNodeSchema.nullable()) });

/**
 * Panel pull requests among GitHub's nodes: head branch in this repository (not a fork) and named like a panel branch.
 * Pure.
 */
function blogPullRequestsOf(blog: ActiveBlog, nodes: ReadonlyArray<PullRequestNode | null>): BlogPullRequest[] {
  const repository: string = `${blog.owner}/${blog.repo}`.toLowerCase();
  return nodes.flatMap((node: PullRequestNode | null): BlogPullRequest[] => {
    const slug: string | null = node === null ? null : blogBranchSlug(node.headRefName);
    if (node === null || slug === null || node.headRepository?.nameWithOwner.toLowerCase() !== repository) {
      return [];
    }
    return [
      {
        id: node.id,
        number: node.number,
        url: node.url,
        slug,
        title: node.title,
        state: node.state === "OPEN" ? "open" : node.state === "MERGED" ? "merged" : "closed",
        autoMerge: node.autoMergeRequest !== null,
        checks: blogChecksState(node.statusCheckRollup?.state ?? null),
        updatedAt: node.updatedAt,
        branch: node.headRefName,
        headOid: node.headRefOid,
      },
    ];
  });
}

/** What the panel shows of a pull request (no node id, branch or head). Pure. */
function blogChangeOf(pull: BlogPullRequest): BlogChange {
  return {
    number: pull.number,
    url: pull.url,
    slug: pull.slug,
    title: pull.title,
    state: pull.state,
    autoMerge: pull.autoMerge,
    checks: pull.checks,
    updatedAt: pull.updatedAt,
  };
}

/** Open pull requests read at once; more than this is a repository the panel was not built for. */
const openPullRequestLimit: number = 100;

const openPullRequestsQuery: string = `query BlogPullRequests($owner: String!, $name: String!, $base: String!) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $base, first: ${openPullRequestLimit}, orderBy: { field: CREATED_AT, direction: DESC }) { nodes { ${pullRequestFields} } }
  }
}`;

const openPullRequestsSchema = z.object({ repository: z.object({ pullRequests: pullRequestConnectionSchema }).nullable() });

/** Open panel pull requests against the default branch. */
async function openBlogPullRequests(platform: Platform, blog: ActiveBlog): Promise<BlogPullRequest[]> {
  const data = await graphqlData(platform, blog, "pull_requests", openPullRequestsQuery, { owner: blog.owner, name: blog.repo, base: blog.branch }, openPullRequestsSchema);
  if (data.repository === null) {
    throw new ProviderApiError("github", "upstream_rejected", "GitHub did not return the repository; check the token's permissions and GITHUB_BLOG_REPO.");
  }
  return blogPullRequestsOf(blog, data.repository.pullRequests.nodes);
}

/**
 * The post's open pull request; none gives null. Two open pull requests for one post cannot be written to safely
 * (which one would merge last is unknown): `blog_conflict` until one is merged or closed on GitHub. Pure.
 */
export function pendingPullRequestOf<Pull extends BlogChange>(pulls: readonly Pull[], slug: string): Pull | null {
  const matching: Pull[] = pulls.filter((pull: Pull): boolean => pull.slug === slug && pull.state === "open");
  if (matching.length > 1) {
    throw new ApiError(
      "blog_conflict",
      `This post has ${matching.length} open pull requests (#${matching.map((pull: Pull): number => pull.number).join(", #")}); merge or close the extra ones on GitHub.`,
    );
  }
  return matching[0] ?? null;
}

const createRefSchema = z.object({ ref: z.string(), object: z.object({ sha: z.string().regex(shaPattern) }) });

/** Creates the branch at `oid`; false if a branch with that name already exists (422). */
async function createBranch(platform: Platform, blog: ActiveBlog, branch: string, oid: string): Promise<boolean> {
  const reply: GithubReply = await github(platform, blog, "create_branch", "POST", repoUrl(blog, "git/refs"), { ref: `refs/heads/${branch}`, sha: oid });
  if (reply.status === 422) {
    log("warn", "blog_branch_exists", { branch, reason: reply.text.slice(0, 200) });
    return false;
  }
  if (reply.status !== 201) {
    throw unexpectedGithubStatus(reply, "create_branch");
  }
  githubJson(createRefSchema, reply, "create_branch");
  return true;
}

/** Body of every panel pull request. */
const pullRequestBody: string = [
  "Saved from the Gistsmith admin panel (Blog).",
  "",
  "Auto-merge (squash) is enabled: GitHub merges this pull request once the required checks pass, and `Deploy web` publishes the site from the default branch.",
  "To hold the change, close the pull request: the panel's next save for this post starts a new one. Disabling auto-merge holds it only until the next save, which turns auto-merge back on.",
].join("\n");

const createdPullSchema = z.object({
  node_id: z.string().min(1),
  number: z.number().int().positive(),
  html_url: z.string().url(),
  title: z.string(),
  updated_at: z.string(),
  head: z.object({ sha: z.string().regex(shaPattern) }),
});

/** Opens the pull request from the panel branch into the default branch. */
async function openPullRequest(platform: Platform, blog: ActiveBlog, branch: string, slug: string, title: string): Promise<BlogPullRequest> {
  const reply: GithubReply = await github(platform, blog, "open_pull_request", "POST", repoUrl(blog, "pulls"), {
    title,
    head: branch,
    base: blog.branch,
    body: pullRequestBody,
  });
  if (reply.status !== 201) {
    throw unexpectedGithubStatus(reply, "open_pull_request");
  }
  const pull = githubJson(createdPullSchema, reply, "open_pull_request");
  return {
    id: pull.node_id,
    number: pull.number,
    url: pull.html_url,
    slug,
    title: pull.title,
    state: "open",
    autoMerge: false,
    checks: "none",
    updatedAt: pull.updated_at,
    branch,
    headOid: pull.head.sha,
  };
}

const enableAutoMergeMutation: string = `mutation BlogAutoMerge($id: ID!) {
  enablePullRequestAutoMerge(input: { pullRequestId: $id, mergeMethod: SQUASH }) { pullRequest { autoMergeRequest { enabledAt } } }
}`;

const enableAutoMergeSchema = z.object({
  enablePullRequestAutoMerge: z.object({ pullRequest: z.object({ autoMergeRequest: z.object({ enabledAt: z.string().nullable() }).nullable() }).nullable() }).nullable(),
});

/**
 * Enables auto-merge (squash) on the pull request; returns null when it is enabled, otherwise GitHub's reason. The
 * commit is already on the branch at this point: a failure is reported to the admin with the pull request (open, not
 * merging) instead of failing the save, and logged as `blog_auto_merge_failed`.
 */
async function enableAutoMerge(platform: Platform, blog: ActiveBlog, pull: BlogPullRequest): Promise<string | null> {
  let result: GraphqlReply<z.output<typeof enableAutoMergeSchema>>;
  try {
    result = await graphqlReply(platform, blog, "auto_merge", enableAutoMergeMutation, { id: pull.id }, enableAutoMergeSchema);
  } catch (error: unknown) {
    if (error instanceof ProviderApiError) {
      log("warn", "blog_auto_merge_failed", { pullRequest: pull.number, reason: error.message });
      return error.message;
    }
    throw error;
  }
  const request = result.data?.enablePullRequestAutoMerge?.pullRequest?.autoMergeRequest ?? null;
  const enabled: boolean = request !== null;
  if (result.errors.length === 0 && enabled) {
    return null;
  }
  const reason: string = result.errors[0]?.message.slice(0, 300) ?? "GitHub did not report auto-merge as enabled.";
  log("warn", "blog_auto_merge_failed", { pullRequest: pull.number, types: result.errors.map((error): string => error.type ?? "unknown").join(","), reason });
  return reason;
}

const pullRequestStateQuery: string = `query BlogPullRequestState($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) { ${pullRequestFields} } }
}`;

const pullRequestStateSchema = z.object({ repository: z.object({ pullRequest: pullRequestNodeSchema.nullable() }).nullable() });

/** The pull request's current state (after a commit to its branch). */
async function pullRequestNow(platform: Platform, blog: ActiveBlog, number: number): Promise<BlogPullRequest> {
  const data = await graphqlData(platform, blog, "pull_request_state", pullRequestStateQuery, { owner: blog.owner, name: blog.repo, number }, pullRequestStateSchema);
  const pull: BlogPullRequest | undefined = blogPullRequestsOf(blog, [data.repository?.pullRequest ?? null])[0];
  if (pull === undefined) {
    throw new ProviderApiError("github", "upstream_unavailable", `GitHub did not return pull request #${number}.`);
  }
  return pull;
}

// MARK: Branch contents

/** Deletes a panel branch; one that is already gone (404/422) is logged as `blog_branch_delete_skipped`. */
async function deleteBranch(platform: Platform, blog: ActiveBlog, branch: string): Promise<void> {
  const removed: GithubReply = await github(platform, blog, "delete_branch", "DELETE", repoUrl(blog, `git/refs/heads/${branch}`), null);
  if (removed.status !== 204 && removed.status !== 422 && removed.status !== 404) {
    throw unexpectedGithubStatus(removed, "delete_branch");
  }
  if (removed.status !== 204) {
    log("warn", "blog_branch_delete_skipped", { branch, status: removed.status });
  }
}

/** A branch's head commit, the post's version on it (null if absent) and the names of the post's image files. */
interface BranchState {
  readonly headOid: string;
  readonly postOid: string | null;
  readonly images: readonly string[];
}

const branchStateQuery: string = `query BlogBranchState($owner: String!, $name: String!, $ref: String!, $post: String!, $images: String!) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $ref) {
      target {
        ... on Commit {
          oid
          post: file(path: $post) { oid }
          images: file(path: $images) { type object { ... on Tree { entries { name type } } } }
        }
      }
    }
  }
}`;

const branchStateSchema = z.object({
  repository: z
    .object({
      ref: z
        .object({
          target: z.object({
            oid: z.string().regex(shaPattern),
            post: z.object({ oid: z.string().regex(shaPattern) }).nullable(),
            images: z
              .object({
                type: z.string(),
                object: z.object({ entries: z.array(z.object({ name: z.string(), type: z.string() })).optional() }).nullable(),
              })
              .nullable(),
          }),
        })
        .nullable(),
    })
    .nullable(),
});

/**
 * The branch's head, the post's version and the image folder's files (one GraphQL request, all from the same commit);
 * null when the branch does not exist. A non-file entry in the folder (a subfolder) is `blog_post_invalid`: the panel
 * only writes files, so it is cleaned up by hand.
 */
async function readBranchState(platform: Platform, blog: ActiveBlog, branch: string, slug: string): Promise<BranchState | null> {
  const data = await graphqlData(
    platform,
    blog,
    "branch_state",
    branchStateQuery,
    { owner: blog.owner, name: blog.repo, ref: `refs/heads/${branch}`, post: postPath(slug), images: imageFolderPath(slug) },
    branchStateSchema,
  );
  if (data.repository === null) {
    throw new ProviderApiError("github", "upstream_rejected", "GitHub did not return the repository; check the token's permissions and GITHUB_BLOG_REPO.");
  }
  const target = data.repository.ref?.target ?? null;
  if (target === null) {
    return null;
  }
  const folder = target.images;
  if (folder !== null && folder.type !== "tree") {
    throw new ApiError("blog_post_invalid", `${imageFolderPath(slug)} is not a folder; fix it manually in the repository.`);
  }
  const entries: ReadonlyArray<{ readonly name: string; readonly type: string }> = folder?.object?.entries ?? [];
  const nested: string | undefined = entries.find((entry): boolean => entry.type !== "blob")?.name;
  if (nested !== undefined) {
    throw new ApiError("blog_post_invalid", `${imageFolderPath(slug)}/${nested} is not a file; the image folder can't contain subfolders, clean it up manually in the repository.`);
  }
  return { headOid: target.oid, postOid: target.post?.oid ?? null, images: entries.map((entry): string => entry.name) };
}

/** The default branch's state; it must exist (otherwise the configuration is wrong). */
async function readDefaultBranchState(platform: Platform, blog: ActiveBlog, slug: string): Promise<BranchState> {
  const state: BranchState | null = await readBranchState(platform, blog, blog.branch, slug);
  if (state === null) {
    throw new ProviderApiError("github", "upstream_rejected", `The branch ${blog.branch} does not exist; check GITHUB_BLOG_BRANCH.`);
  }
  return state;
}

/** File changes of one commit (GraphQL `FileChanges`; addition contents are base64). */
interface FileChanges {
  readonly additions: ReadonlyArray<{ readonly path: string; readonly contents: string }>;
  readonly deletions: ReadonlyArray<{ readonly path: string }>;
}

/** A commit planned against a branch state: headline, file changes and the path whose new version the caller needs. */
interface PlannedCommit {
  readonly headline: string;
  readonly changes: FileChanges;
  readonly resultPath: string;
}

const createCommitMutation: string = `mutation BlogCommit($input: CreateCommitOnBranchInput!, $path: String!) {
  createCommitOnBranch(input: $input) { commit { oid file(path: $path) { oid } } }
}`;

const createCommitSchema = z.object({
  createCommitOnBranch: z.object({ commit: z.object({ oid: z.string().regex(shaPattern), file: z.object({ oid: z.string().regex(shaPattern) }).nullable() }) }).nullable(),
});

/** A commit that landed: its oid and the version of `resultPath` in it (null if the commit removed it). */
interface Commit {
  readonly oid: string;
  readonly fileOid: string | null;
}

/** GraphQL errors saying the branch moved (`expectedHeadOid` did not match) or vanished since it was read. Pure. */
function isStaleBranch(errors: readonly GraphqlError[]): boolean {
  return errors.some(
    (error): boolean => error.type === "STALE_DATA" || error.type === "NOT_FOUND" || error.message.includes("Expected branch to point to"),
  );
}

/** Commits on the branch at the expected head (`createCommitOnBranch`); null when the branch moved or vanished. */
async function commitOnBranch(platform: Platform, blog: ActiveBlog, branch: string, expectedHeadOid: string, planned: PlannedCommit): Promise<Commit | null> {
  const result = await graphqlReply(
    platform,
    blog,
    "commit",
    createCommitMutation,
    {
      input: {
        branch: { repositoryNameWithOwner: `${blog.owner}/${blog.repo}`, branchName: branch },
        expectedHeadOid,
        message: { headline: planned.headline },
        fileChanges: planned.changes,
      },
      path: planned.resultPath,
    },
    createCommitSchema,
  );
  if (result.errors.length > 0) {
    if (isStaleBranch(result.errors)) {
      return null;
    }
    throw graphqlRejected("commit", result.errors);
  }
  const commit = result.data?.createCommitOnBranch?.commit ?? null;
  if (commit === null) {
    throw invalidGithubResponse({ status: 200, text: "" }, "commit", "createCommitOnBranch is empty");
  }
  return { oid: commit.oid, fileOid: commit.file?.oid ?? null };
}

/** How often a write is re-planned when the branch or pull request changed under it. */
const writeAttempts: number = 3;

/** A write that landed in a pull request. */
interface LandedWrite {
  readonly planned: PlannedCommit;
  readonly commit: Commit;
  readonly result: BlogWriteResult;
}

/**
 * Writes one commit for the post through its pull request. `plan` turns the branch's current state into the commit
 * (and throws the request's own errors: `blog_post_exists`, `blog_conflict`, `not_found`…); it is evaluated against the
 * open pull request's branch if there is one, otherwise against the default branch, and the first write opens the pull
 * request (titled `title`) and enables auto-merge. When the branch moves in between, the pull request is merged or
 * closed before the commit lands on it, or the new branch name is taken, the write is re-read and re-planned with a
 * `blog_write_retry` warning, at most `writeAttempts` times, then `blog_conflict`.
 */
async function writeThroughPullRequest(
  platform: Platform,
  blog: ActiveBlog,
  slug: string,
  title: string,
  plan: (state: BranchState) => PlannedCommit,
  now: Date,
): Promise<LandedWrite> {
  for (let attempt: number = 1; attempt <= writeAttempts; attempt += 1) {
    const pending: BlogPullRequest | null = pendingPullRequestOf(await openBlogPullRequests(platform, blog), slug);
    const branch: string = pending?.branch ?? blogBranchName(slug, now);
    const state: BranchState | null = pending === null ? await readDefaultBranchState(platform, blog, slug) : await readBranchState(platform, blog, pending.branch, slug);
    if (state === null) {
      log("warn", "blog_write_retry", { slug, attempt, reason: "branch_missing" });
      continue;
    }
    const planned: PlannedCommit = plan(state);
    if (pending === null && !(await createBranch(platform, blog, branch, state.headOid))) {
      log("warn", "blog_write_retry", { slug, attempt, reason: "branch_exists" });
      continue;
    }
    const commit: Commit | null = await commitOnBranch(platform, blog, branch, state.headOid, planned);
    if (commit === null) {
      log("warn", "blog_write_retry", { slug, attempt, reason: "stale_branch" });
      // The branch this attempt created holds no commit and has no pull request: remove it so the next attempt can
      // create it again from the new head.
      if (pending === null) {
        await deleteBranch(platform, blog, branch);
      }
      continue;
    }
    const pull: BlogPullRequest = pending === null ? await openPullRequest(platform, blog, branch, slug, title) : await pullRequestNow(platform, blog, pending.number);
    // A pull request merged or closed before this commit reached its branch leaves the commit outside the default
    // branch: write it again through a new pull request.
    if (pull.state === "closed" || (pull.state === "merged" && pull.headOid !== commit.oid)) {
      log("warn", "blog_write_retry", { slug, attempt, reason: "pull_request_finished", pullRequest: pull.number });
      continue;
    }
    const autoMergeError: string | null = pull.state === "open" && !pull.autoMerge ? await enableAutoMerge(platform, blog, pull) : null;
    const change: BlogChange = { ...blogChangeOf(pull), autoMerge: pull.autoMerge || (pull.state === "open" && autoMergeError === null) };
    return { planned, commit, result: { change, autoMergeError } };
  }
  throw new ApiError("blog_conflict", "The repository kept changing during the save; try again shortly.");
}

// MARK: Reading posts

/** Post file in the repository: its version and text. */
interface RepoFile {
  readonly sha: string;
  readonly text: string;
}

const contentsFileSchema = z.object({
  type: z.literal("file"),
  sha: z.string().regex(shaPattern),
  encoding: z.literal("base64"),
  content: z.string(),
});

/** The post file on `branch`; null if absent. Broken base64 or UTF-8 is `blog_post_invalid`. */
async function readFile(platform: Platform, blog: ActiveBlog, branch: string, slug: string): Promise<RepoFile | null> {
  const reply: GithubReply = await github(platform, blog, "read", "GET", `${repoUrl(blog, `contents/${postPath(slug)}`)}?ref=${encodeURIComponent(branch)}`, null);
  if (reply.status === 404) {
    return null;
  }
  if (reply.status !== 200) {
    throw unexpectedGithubStatus(reply, "read");
  }
  const file = githubJson(contentsFileSchema, reply, "read");
  let text: string;
  try {
    text = decodeUtf8Strict(base64Decode(file.content.replace(/\s+/g, "")));
  } catch (error: unknown) {
    throw invalidFile(slug, `could not decode content (${errorName(error)})`);
  }
  return { sha: file.sha, text };
}

/** Listed post as the API returns it. Pure. */
function blogSummaryOf(slug: string, sha: string, frontMatter: BlogFrontMatter, change: BlogChange | null, today: string): BlogPostSummary {
  return { slug, ...frontMatter, status: blogPostStatus(frontMatter.draft, frontMatter.published, today), sha, change };
}

/** Post with its body as the API returns it. Pure. */
function blogPostOf(slug: string, sha: string, parsed: ParsedBlogFile, change: BlogChange | null, today: string): BlogPost {
  return { ...blogSummaryOf(slug, sha, parsed.frontMatter, change, today), body: parsed.body };
}

/** Post order: newest first, same-day posts by title (like the site's blog index). Pure. */
export function compareBlogPosts(a: BlogFrontMatter, b: BlogFrontMatter): number {
  return b.published.localeCompare(a.published) || a.title.localeCompare(b.title);
}

/** Merged and closed panel pull requests shown in the list (most recently updated first). */
const recentChangeLimit: number = 10;

const postsQuery: string = `query BlogPosts($owner: String!, $name: String!, $expression: String!, $base: String!) {
  repository(owner: $owner, name: $name) {
    object(expression: $expression) {
      ... on Tree {
        entries { name type oid object { ... on Blob { text isTruncated } } }
      }
    }
    open: pullRequests(states: OPEN, baseRefName: $base, first: ${openPullRequestLimit}, orderBy: { field: CREATED_AT, direction: DESC }) { nodes { ${pullRequestFields} } }
    finished: pullRequests(states: [MERGED, CLOSED], baseRefName: $base, first: 100, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes { ${pullRequestFields} } }
  }
}`;

const blobSchema = z.object({ oid: z.string().regex(shaPattern), text: z.string().nullable().optional(), isTruncated: z.boolean().optional() });

const postsSchema = z.object({
  repository: z
    .object({
      object: z
        .object({
          entries: z.array(
            z.object({
              name: z.string(),
              type: z.string(),
              oid: z.string(),
              object: z.object({ text: z.string().nullable().optional(), isTruncated: z.boolean().optional() }).nullable(),
            }),
          ),
        })
        .nullable(),
      open: pullRequestConnectionSchema,
      finished: pullRequestConnectionSchema,
    })
    .nullable(),
});

/** The post's text from a GraphQL blob; a missing or truncated text is `blog_post_invalid`. Pure. */
function blobText(slug: string, object: { readonly text?: string | null | undefined; readonly isTruncated?: boolean | undefined } | null): string {
  const text: string | null | undefined = object?.text;
  if (text === null || text === undefined || object?.isTruncated === true) {
    throw invalidFile(slug, "could not read the text");
  }
  return text;
}

/** Every open pull request's version of its post (one GraphQL request with an alias per pull request). */
async function pendingPostFiles(platform: Platform, blog: ActiveBlog, pulls: readonly BlogPullRequest[]): Promise<Map<number, RepoFile | null>> {
  if (pulls.length === 0) {
    return new Map();
  }
  const declarations: string = pulls.map((_: BlogPullRequest, index: number): string => `$e${index}: String!`).join(", ");
  const selections: string = pulls.map((_: BlogPullRequest, index: number): string => `p${index}: object(expression: $e${index}) { ... on Blob { oid text isTruncated } }`).join("\n");
  const variables: Record<string, string> = { owner: blog.owner, name: blog.repo };
  pulls.forEach((pull: BlogPullRequest, index: number): void => {
    variables[`e${index}`] = `${pull.headOid}:${postPath(pull.slug)}`;
  });
  const schema = z.object({ repository: z.record(z.string(), blobSchema.nullable()).nullable() });
  const data = await graphqlData(platform, blog, "pending_posts", `query BlogPendingPosts($owner: String!, $name: String!, ${declarations}) {\n  repository(owner: $owner, name: $name) {\n${selections}\n  }\n}`, variables, schema);
  if (data.repository === null) {
    throw new ProviderApiError("github", "upstream_rejected", "GitHub did not return the repository; check the token's permissions and GITHUB_BLOG_REPO.");
  }
  const repository: Record<string, z.output<typeof blobSchema> | null> = data.repository;
  return new Map(
    pulls.map((pull: BlogPullRequest, index: number): [number, RepoFile | null] => {
      const blob = repository[`p${index}`] ?? null;
      return [pull.number, blob === null ? null : { sha: blob.oid, text: blobText(pull.slug, blob) }];
    }),
  );
}

/** The post list and the panel's pull requests. */
export interface BlogPostList {
  readonly posts: BlogPostSummary[];
  /** Open panel pull requests and the most recently merged or closed ones, most recently updated first. */
  readonly changes: BlogChange[];
}

/**
 * Every post (without body), newest first, as the default branch has it with each open pull request's version laid
 * over it (the post carries that pull request as `change`; a post the pull request removes keeps its default-branch
 * version with the `change`). A missing folder (the last post was removed too: git keeps no empty folders) is an
 * empty list. Non-`.md` files are ignored like the site's content collection; an unreadable post is
 * `blog_post_invalid` (the site cannot build either). `today`: UTC day.
 */
export async function listBlogPosts(platform: Platform, blog: ActiveBlog, today: string): Promise<BlogPostList> {
  const data = await graphqlData(
    platform,
    blog,
    "list",
    postsQuery,
    { owner: blog.owner, name: blog.repo, expression: `${blog.branch}:${blogDirectory}`, base: blog.branch },
    postsSchema,
  );
  if (data.repository === null) {
    throw new ProviderApiError("github", "upstream_rejected", "GitHub did not return the post list; check the token's permissions and GITHUB_BLOG_REPO.");
  }
  const open: BlogPullRequest[] = blogPullRequestsOf(blog, data.repository.open.nodes);
  const finished: BlogPullRequest[] = blogPullRequestsOf(blog, data.repository.finished.nodes).slice(0, recentChangeLimit);
  const pendingFiles: Map<number, RepoFile | null> = await pendingPostFiles(platform, blog, open);
  const posts: Map<string, BlogPostSummary> = new Map();
  for (const entry of data.repository.object?.entries ?? []) {
    if (entry.type !== "blob" || !entry.name.endsWith(".md")) {
      continue;
    }
    const slug: string = entry.name.slice(0, -3);
    if (slug.length > blogSlugMaxLength || !blogSlugPattern.test(slug)) {
      throw invalidFile(slug, "file name is not a valid slug");
    }
    posts.set(slug, blogSummaryOf(slug, entry.oid, parseBlogFile(slug, blobText(slug, entry.object)).frontMatter, null, today));
  }
  for (const pull of open) {
    const file: RepoFile | null = pendingFiles.get(pull.number) ?? null;
    const current: BlogPostSummary | undefined = posts.get(pull.slug);
    if (file !== null) {
      posts.set(pull.slug, blogSummaryOf(pull.slug, file.sha, parseBlogFile(pull.slug, file.text).frontMatter, blogChangeOf(pull), today));
    } else if (current !== undefined) {
      posts.set(pull.slug, { ...current, change: blogChangeOf(pull) });
    }
  }
  const changes: BlogChange[] = [...open, ...finished].map(blogChangeOf).sort((a: BlogChange, b: BlogChange): number => b.updatedAt.localeCompare(a.updatedAt));
  return { posts: [...posts.values()].sort(compareBlogPosts), changes };
}

/** One post as its open pull request has it (or the default branch without one); absent is `not_found`. */
export async function getBlogPost(platform: Platform, blog: ActiveBlog, slug: string, today: string): Promise<BlogPost> {
  const pending: BlogPullRequest | null = pendingPullRequestOf(await openBlogPullRequests(platform, blog), slug);
  const file: RepoFile | null = await readFile(platform, blog, pending?.branch ?? blog.branch, slug);
  if (file === null) {
    throw new ApiError("not_found", pending === null ? "No such post." : `No such post: pull request #${pending.number} removes it.`);
  }
  return blogPostOf(slug, file.sha, parseBlogFile(slug, file.text), pending === null ? null : blogChangeOf(pending), today);
}

// MARK: Writing posts

/** Save result: whether the file is new, the post after the save and the pull request it landed in. */
export interface SavedBlogPost extends BlogWriteResult {
  readonly created: boolean;
  readonly post: BlogPost;
}

/**
 * Creates or updates the post (`blog: <title>` commit) through its pull request. A new post sends `sha` null: an
 * existing file is `blog_post_exists`. An update sends the version the panel opened: a removed or changed file is
 * `blog_conflict` and nothing is written. Versions are compared on the open pull request's branch when there is one,
 * otherwise on the default branch.
 */
export async function saveBlogPost(platform: Platform, blog: ActiveBlog, slug: string, input: BlogPostInput, today: string, now: Date): Promise<SavedBlogPost> {
  const frontMatter: BlogFrontMatter = {
    title: input.title,
    description: input.description,
    author: input.author,
    published: input.published,
    updated: input.updated,
    cover: input.cover,
    draft: input.draft,
  };
  const text: string = serializeBlogPost(frontMatter, input.body);
  const headline: string = `blog: ${input.title}`;
  const landed: LandedWrite = await writeThroughPullRequest(
    platform,
    blog,
    slug,
    headline,
    (state: BranchState): PlannedCommit => {
      if (input.sha === null && state.postOid !== null) {
        throw new ApiError("blog_post_exists", "A post with this slug already exists.");
      }
      if (input.sha !== null && state.postOid !== input.sha) {
        throw new ApiError("blog_conflict", "The post changed or was deleted after you opened it; reload and try again.");
      }
      return { headline, changes: { additions: [{ path: postPath(slug), contents: base64Encode(utf8(text)) }], deletions: [] }, resultPath: postPath(slug) };
    },
    now,
  );
  if (landed.commit.fileOid === null) {
    throw invalidGithubResponse({ status: 200, text: "" }, "commit", "the saved post is missing from the commit");
  }
  return {
    created: input.sha === null,
    post: blogPostOf(slug, landed.commit.fileOid, parseBlogFile(slug, text), landed.result.change, today),
    change: landed.result.change,
    autoMergeError: landed.result.autoMergeError,
  };
}

/** Deletion result: the removed image count and the pull request (closed when the post existed only in it). */
export interface DeletedBlogPost extends BlogWriteResult {
  readonly images: number;
}

/** Commit that removes the post and its image folder, if the version matches. Pure. */
function deletionPlan(slug: string, sha: string, state: BranchState): PlannedCommit {
  if (state.postOid === null) {
    throw new ApiError("not_found", "No such post.");
  }
  if (state.postOid !== sha) {
    throw new ApiError("blog_conflict", "The post changed after you opened it; reload and try again.");
  }
  return {
    headline: `blog: remove ${slug}`,
    changes: {
      additions: [],
      deletions: [{ path: postPath(slug) }, ...state.images.map((name: string): { readonly path: string } => ({ path: `${imageFolderPath(slug)}/${name}` }))],
    },
    resultPath: postPath(slug),
  };
}

const closedPullSchema = z.object({ state: z.literal("closed"), updated_at: z.string() });

/**
 * Removes a post that exists only in its open pull request (never merged): closing the pull request and deleting its
 * branch removes it with its images, without an empty change reaching the default branch.
 */
async function discardPendingPost(platform: Platform, blog: ActiveBlog, pull: BlogPullRequest, slug: string, sha: string): Promise<DeletedBlogPost> {
  const state: BranchState | null = await readBranchState(platform, blog, pull.branch, slug);
  if (state === null) {
    throw new ApiError("blog_conflict", "The post's pull request changed while deleting; reload and try again.");
  }
  const planned: PlannedCommit = deletionPlan(slug, sha, state);
  const closed: GithubReply = await github(platform, blog, "close_pull_request", "PATCH", repoUrl(blog, `pulls/${pull.number}`), { state: "closed" });
  if (closed.status !== 200) {
    throw unexpectedGithubStatus(closed, "close_pull_request");
  }
  const result = githubJson(closedPullSchema, closed, "close_pull_request");
  await deleteBranch(platform, blog, pull.branch);
  return {
    images: planned.changes.deletions.length - 1,
    change: { ...blogChangeOf(pull), state: "closed", autoMerge: false, updatedAt: result.updated_at },
    autoMergeError: null,
  };
}

/**
 * Removes the post and its image folder (`web/public/blog/<slug>/`) in one `blog: remove <slug>` commit through its
 * pull request. A post that exists only in its open pull request is removed by closing that pull request
 * (`discardPendingPost`). Missing post `not_found`, version other than `sha` `blog_conflict`.
 */
export async function deleteBlogPost(platform: Platform, blog: ActiveBlog, slug: string, sha: string, now: Date): Promise<DeletedBlogPost> {
  const pending: BlogPullRequest | null = pendingPullRequestOf(await openBlogPullRequests(platform, blog), slug);
  if (pending !== null && (await readDefaultBranchState(platform, blog, slug)).postOid === null) {
    return discardPendingPost(platform, blog, pending, slug, sha);
  }
  const landed: LandedWrite = await writeThroughPullRequest(platform, blog, slug, `blog: remove ${slug}`, (state: BranchState): PlannedCommit => deletionPlan(slug, sha, state), now);
  // Every deletion but the post file itself is an image.
  return { images: landed.planned.changes.deletions.length - 1, ...landed.result };
}

/** Görsel adı: küçük harf, rakam ve tire, `.webp` uzantılı; en çok 80 karakter (yazının klasöründe). */
export const blogImageNamePattern: RegExp = /^[a-z0-9-]+\.webp$/;
const blogImageNameMaxLength: number = 80;
/** Görselin en büyük boyu (bayt, çözülmüş): panel tarayıcıda küçültüp WebP'ye çevirir, büyükse yüklemez. */
export const blogImageMaxBytes: number = 600 * 1024;
/** Görselin en büyük genişliği (piksel): panel bu genişliğe küçültür. */
export const blogImageMaxWidth: number = 1600;
/** `PUT` isteğinin en büyük gövdesi (bayt): en büyük görselin base64'ü ve JSON sarmalı sığar. */
export const blogImageRequestMaxBytes: number = Math.ceil(blogImageMaxBytes / 3) * 4 + 1024;

/** `PUT /v1/admin/blog/posts/{kısa ad}/images/{ad}` gövdesi: görselin standart base64'ü (dolgulu, satır sonsuz). */
export const blogImageInputSchema = z.strictObject({
  data: z.string().min(4).regex(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/),
});

/** Yüklenen görsel: sitedeki yolu, GitHub sürümü ve boyutu. */
export interface SavedBlogImage extends BlogWriteResult {
  readonly path: string;
  readonly sha: string;
  readonly bytes: number;
  readonly width: number;
  readonly height: number;
}

/** Yoldaki görsel adını doğrular; geçersizse `bad_request`. Saf fonksiyondur. */
export function parseBlogImageName(value: string): string {
  if (value.length > blogImageNameMaxLength || !blogImageNamePattern.test(value)) {
    throw new ApiError("bad_request", "The image name must contain only lowercase letters, digits and hyphens and end with .webp (at most 80 characters).");
  }
  return value;
}

/** Görselin piksel boyutu. */
export interface ImageDimensions {
  readonly width: number;
  readonly height: number;
}

/** Doğrulanmış görsel: baytları ve boyutu. */
export interface DecodedBlogImage {
  readonly bytes: Uint8Array;
  readonly dimensions: ImageDimensions;
}

/** Dört baytlık ASCII etiket mi. Saf fonksiyondur. */
function hasTag(bytes: Uint8Array, offset: number, tag: string): boolean {
  return [...tag].every((char: string, index: number): boolean => bytes[offset + index] === char.charCodeAt(0));
}

/** Küçük sonlu (little-endian) işaretsiz tamsayı. Saf fonksiyondur. */
function littleEndian(bytes: Uint8Array, offset: number, length: number): number {
  let value: number = 0;
  for (let index: number = length - 1; index >= 0; index -= 1) {
    value = value * 256 + (bytes[offset + index] ?? 0);
  }
  return value;
}

/**
 * WebP'nin boyutu: RIFF/WEBP imzası, RIFF boyunun dosyayla tutması ve ilk parça (`VP8 `, `VP8L`, `VP8X`). WebP değilse
 * `unsupported_media_type`. Sitenin derlemesi aynı kurallarla okur (`web/src/lib/blog-images.ts` `webpSize`). Saf
 * fonksiyondur.
 */
export function webpDimensions(bytes: Uint8Array): ImageDimensions {
  if (bytes.length < 30 || !hasTag(bytes, 0, "RIFF") || !hasTag(bytes, 8, "WEBP") || littleEndian(bytes, 4, 4) + 8 !== bytes.length) {
    throw new ApiError("unsupported_media_type", "The image is not WebP (missing RIFF/WEBP signature or truncated file).");
  }
  if (hasTag(bytes, 12, "VP8 ")) {
    return { width: littleEndian(bytes, 26, 2) & 0x3fff, height: littleEndian(bytes, 28, 2) & 0x3fff };
  }
  if (hasTag(bytes, 12, "VP8L")) {
    const bits: number = littleEndian(bytes, 21, 4);
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (hasTag(bytes, 12, "VP8X")) {
    return { width: littleEndian(bytes, 24, 3) + 1, height: littleEndian(bytes, 27, 3) + 1 };
  }
  throw new ApiError("unsupported_media_type", "The image is not WebP (first chunk is not VP8, VP8L or VP8X).");
}

/**
 * Gövdedeki base64'ü çözer ve görseli doğrular: en çok `blogImageMaxBytes` (`payload_too_large`), WebP
 * (`unsupported_media_type`), genişlik en çok `blogImageMaxWidth` ve boyutlar sıfır değil (`invalid_body`). Saf
 * fonksiyondur.
 */
export function decodeBlogImage(data: string): DecodedBlogImage {
  const bytes: Uint8Array = base64Decode(data);
  if (bytes.length > blogImageMaxBytes) {
    throw new ApiError("payload_too_large", `The image can be at most ${blogImageMaxBytes} bytes (received ${bytes.length}).`);
  }
  const dimensions: ImageDimensions = webpDimensions(bytes);
  if (dimensions.width === 0 || dimensions.height === 0 || dimensions.width > blogImageMaxWidth) {
    throw new ApiError("invalid_body", `The image must be at most ${blogImageMaxWidth} pixels wide (received ${dimensions.width}×${dimensions.height}).`);
  }
  return { bytes, dimensions };
}

/**
 * Adds the image to the post's folder (`blog: image <slug>/<name>` commit) through the post's pull request. The post
 * must exist there (`not_found`: the folder is named after the slug, so the post is saved first); an image with the same
 * name is `blog_image_exists` (images are never replaced, a new one gets a new name).
 */
export async function saveBlogImage(platform: Platform, blog: ActiveBlog, slug: string, name: string, image: DecodedBlogImage, now: Date): Promise<SavedBlogImage> {
  const repoPath: string = `${imageFolderPath(slug)}/${name}`;
  const headline: string = `blog: image ${slug}/${name}`;
  const landed: LandedWrite = await writeThroughPullRequest(
    platform,
    blog,
    slug,
    headline,
    (state: BranchState): PlannedCommit => {
      if (state.postOid === null) {
        throw new ApiError("not_found", "No such post; save the post before adding images.");
      }
      if (state.images.includes(name)) {
        throw new ApiError("blog_image_exists", "This post already has an image with this name; choose another name.");
      }
      return { headline, changes: { additions: [{ path: repoPath, contents: base64Encode(image.bytes) }], deletions: [] }, resultPath: repoPath };
    },
    now,
  );
  if (landed.commit.fileOid === null) {
    throw invalidGithubResponse({ status: 200, text: "" }, "commit", "the uploaded image is missing from the commit");
  }
  return {
    path: `/blog/${slug}/${name}`,
    sha: landed.commit.fileOid,
    bytes: image.bytes.length,
    width: image.dimensions.width,
    height: image.dimensions.height,
    change: landed.result.change,
    autoMergeError: landed.result.autoMergeError,
  };
}
