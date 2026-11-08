import { describe, expect, it, vi } from "vitest";
import { filmPalettes } from "../../web/src/lib/film";
import realPostNoBot from "../../web/src/content/blog/meeting-notes-on-mac-without-a-bot.md?raw";
import realPostRecording from "../../web/src/content/blog/record-teams-zoom-google-meet-on-mac.md?raw";
import realPostTasks from "../../web/src/content/blog/turn-a-meeting-into-a-task-list.md?raw";
import {
  blogBranchName,
  blogBranchSlug,
  blogChecksState,
  blogCoverPalettes,
  blogImageMaxBytes,
  parseBlogFile,
  pendingPullRequestOf,
  serializeBlogPost,
  webpDimensions,
} from "../src/blog";
import { base64Decode, base64Encode, hexEncode, randomId, utf8 } from "../src/crypto";
import type { Env } from "../src/env";
import { type Harness, type Session, defaultHarness, envWith, expectError, req, signIn, signInWithGoogle } from "./helpers";

const token: string = "github_pat_test_0123456789abcdefghij";
const repository: string = "senoldogan-labs/AI-Notepad";
const repoRoot: string = `https://api.github.com/repos/${repository}/`;
const contentsPrefix: string = `${repoRoot}contents/`;
const postDirectory: string = "web/src/content/blog/";
const imageDirectory: string = "web/public/blog/";

/** A file in the fake repository: its version (content hash, like git) and bytes. */
interface FakeBlob {
  readonly oid: string;
  readonly bytes: Uint8Array;
}

/** A commit of the fake repository: the whole tree as path → file. */
type FakeTree = ReadonlyMap<string, FakeBlob>;

/** A pull request of the fake repository. */
interface FakePull {
  readonly id: string;
  readonly number: number;
  readonly branch: string;
  readonly title: string;
  state: "OPEN" | "MERGED" | "CLOSED";
  headOid: string;
  autoMerge: boolean;
  checks: string | null;
  updatedAt: string;
}

/** A commit made through `createCommitOnBranch`. */
interface FakeCommit {
  readonly branch: string;
  readonly headline: string;
  readonly additions: readonly string[];
  readonly deletions: readonly string[];
}

/**
 * Fake GitHub: commits (oid → tree), branches (name → commit oid), pull requests and the commits written through
 * GraphQL. `staleOnce` makes the next `createCommitOnBranch` report that the branch moved; `finishBeforeNextCommit`
 * merges the branch's open pull request just before the next commit lands on it; `autoMergeError` makes
 * `enablePullRequestAutoMerge` fail with that message.
 */
interface FakeGithub {
  readonly trees: Map<string, FakeTree>;
  readonly branches: Map<string, string>;
  readonly pulls: FakePull[];
  readonly commits: FakeCommit[];
  readonly flags: { staleOnce: boolean; finishBeforeNextCommit: boolean; autoMergeError: string | null };
}

/** SHA-1 as 40 hex characters. */
async function sha1(bytes: Uint8Array): Promise<string> {
  return hexEncode(new Uint8Array(await crypto.subtle.digest("SHA-1", bytes)));
}

/** A file's version: the hash of its content (same content, same version, like a git blob). */
async function blobOf(bytes: Uint8Array): Promise<FakeBlob> {
  return { oid: await sha1(new Uint8Array([...utf8("blob\n"), ...bytes])), bytes };
}

/** GitHub's base64 with a line break every 60 characters. */
function githubBase64(bytes: Uint8Array): string {
  return (base64Encode(bytes).match(/.{1,60}/g) ?? []).join("\n");
}

/** The tree a branch points to. */
function branchTree(fake: FakeGithub, branch: string): FakeTree {
  const oid: string | undefined = fake.branches.get(branch);
  const tree: FakeTree | undefined = oid === undefined ? undefined : fake.trees.get(oid);
  if (tree === undefined) {
    throw new Error(`no branch ${branch}`);
  }
  return tree;
}

/** Commits a new tree on the branch (no checks); returns the new oid. */
async function commitTree(fake: FakeGithub, branch: string, tree: FakeTree): Promise<string> {
  const oid: string = await sha1(utf8(`${branch}\n${fake.trees.size}\n${randomId()}`));
  fake.trees.set(oid, tree);
  fake.branches.set(branch, oid);
  return oid;
}

/** Writes post files straight to main (the repository's starting state). */
async function seedMain(fake: FakeGithub, files: Readonly<Record<string, string | Uint8Array>>): Promise<void> {
  const tree: Map<string, FakeBlob> = new Map(branchTree(fake, "main"));
  for (const [path, content] of Object.entries(files)) {
    tree.set(path, await blobOf(typeof content === "string" ? utf8(content) : content));
  }
  await commitTree(fake, "main", tree);
}

/** Squash-merges the pull request: main takes the branch's tree. */
async function mergePull(fake: FakeGithub, number: number): Promise<void> {
  const pull: FakePull | undefined = fake.pulls.find((candidate: FakePull): boolean => candidate.number === number);
  if (pull === undefined) {
    throw new Error(`no pull request ${number}`);
  }
  await commitTree(fake, "main", branchTree(fake, pull.branch));
  pull.state = "MERGED";
}

/** Text of a file on a branch; null when absent. */
function fileText(fake: FakeGithub, branch: string, path: string): string | null {
  const blob: FakeBlob | undefined = branchTree(fake, branch).get(path);
  return blob === undefined ? null : new TextDecoder().decode(blob.bytes);
}

/** GraphQL node of a pull request. */
function pullNode(pull: FakePull): object {
  return {
    id: pull.id,
    number: pull.number,
    url: `https://github.com/${repository}/pull/${pull.number}`,
    title: pull.title,
    state: pull.state,
    headRefName: pull.branch,
    headRefOid: pull.headOid,
    updatedAt: pull.updatedAt,
    headRepository: { nameWithOwner: repository },
    autoMergeRequest: pull.autoMerge ? { enabledAt: pull.updatedAt } : null,
    statusCheckRollup: pull.checks === null ? null : { state: pull.checks },
  };
}

/** Entries directly under a folder of a tree. */
function folderEntries(tree: FakeTree, folder: string): Array<{ name: string; path: string; blob: FakeBlob }> {
  return [...tree.entries()]
    .filter(([path]: [string, FakeBlob]): boolean => path.startsWith(folder) && !path.slice(folder.length).includes("/"))
    .map(([path, blob]: [string, FakeBlob]) => ({ name: path.slice(folder.length), path, blob }));
}

type Variables = Record<string, unknown>;

/** GraphQL: post list, pending posts, open pull requests, branch state, commits, auto-merge and pull request state. */
async function graphql(fake: FakeGithub, request: Request): Promise<Response> {
  const body: { query: string; variables: Variables } = await request.json();
  const variables: Variables = body.variables;
  expect([variables.owner, variables.name].filter((value: unknown): boolean => value !== undefined)).toEqual(
    body.query.includes("mutation") ? [] : ["senoldogan-labs", "AI-Notepad"],
  );
  const open: FakePull[] = fake.pulls.filter((pull: FakePull): boolean => pull.state === "OPEN");
  if (body.query.includes("query BlogPosts(")) {
    expect(variables).toMatchObject({ expression: "main:web/src/content/blog", base: "main" });
    const entries = folderEntries(branchTree(fake, "main"), postDirectory).map((entry) => ({
      name: entry.name,
      type: "blob",
      oid: entry.blob.oid,
      object: { text: new TextDecoder().decode(entry.blob.bytes), isTruncated: false },
    }));
    const finished: FakePull[] = fake.pulls.filter((pull: FakePull): boolean => pull.state !== "OPEN");
    return Response.json({
      data: { repository: { object: entries.length === 0 ? null : { entries }, open: { nodes: open.map(pullNode) }, finished: { nodes: finished.map(pullNode) } } },
    });
  }
  if (body.query.includes("query BlogPendingPosts(")) {
    const repositoryData: Record<string, object | null> = {};
    for (const [key, value] of Object.entries(variables)) {
      if (!/^e\d+$/.test(key)) {
        continue;
      }
      const [oid, path] = String(value).split(":") as [string, string];
      const blob: FakeBlob | undefined = fake.trees.get(oid)?.get(path);
      repositoryData[`p${key.slice(1)}`] = blob === undefined ? null : { oid: blob.oid, text: new TextDecoder().decode(blob.bytes), isTruncated: false };
    }
    return Response.json({ data: { repository: repositoryData } });
  }
  if (body.query.includes("query BlogPullRequests(")) {
    expect(variables.base).toBe("main");
    return Response.json({ data: { repository: { pullRequests: { nodes: open.map(pullNode) } } } });
  }
  if (body.query.includes("query BlogPullRequestState(")) {
    const pull: FakePull | undefined = fake.pulls.find((candidate: FakePull): boolean => candidate.number === variables.number);
    return Response.json({ data: { repository: { pullRequest: pull === undefined ? null : pullNode(pull) } } });
  }
  if (body.query.includes("query BlogBranchState(")) {
    const ref: string = String(variables.ref).replace(/^refs\/heads\//, "");
    const oid: string | undefined = fake.branches.get(ref);
    if (oid === undefined) {
      return Response.json({ data: { repository: { ref: null } } });
    }
    const tree: FakeTree = fake.trees.get(oid) ?? new Map();
    const post: FakeBlob | undefined = tree.get(String(variables.post));
    const images = folderEntries(tree, `${String(variables.images)}/`);
    return Response.json({
      data: {
        repository: {
          ref: {
            target: {
              oid,
              post: post === undefined ? null : { oid: post.oid },
              images: images.length === 0 ? null : { type: "tree", object: { entries: images.map((image) => ({ name: image.name, type: "blob" })) } },
            },
          },
        },
      },
    });
  }
  if (body.query.includes("mutation BlogCommit(")) {
    const input = (
      variables as {
        input: {
          branch: { repositoryNameWithOwner: string; branchName: string };
          expectedHeadOid: string;
          message: { headline: string };
          fileChanges: { additions: Array<{ path: string; contents: string }>; deletions: Array<{ path: string }> };
        };
      }
    ).input;
    expect(input.branch.repositoryNameWithOwner).toBe(repository);
    const branch: string = input.branch.branchName;
    const pull: FakePull | undefined = open.find((candidate: FakePull): boolean => candidate.branch === branch);
    if (fake.flags.finishBeforeNextCommit && pull !== undefined) {
      fake.flags.finishBeforeNextCommit = false;
      await mergePull(fake, pull.number);
    }
    if (fake.flags.staleOnce || input.expectedHeadOid !== fake.branches.get(branch)) {
      fake.flags.staleOnce = false;
      await commitTree(fake, branch, branchTree(fake, branch));
      return Response.json({ data: { createCommitOnBranch: null }, errors: [{ type: "STALE_DATA", message: `Expected branch to point to "${input.expectedHeadOid}" but it did not. Pull and try again.` }] });
    }
    const tree: Map<string, FakeBlob> = new Map(branchTree(fake, branch));
    for (const addition of input.fileChanges.additions) {
      tree.set(addition.path, await blobOf(base64Decode(addition.contents)));
    }
    for (const deletion of input.fileChanges.deletions) {
      tree.delete(deletion.path);
    }
    const oid: string = await commitTree(fake, branch, tree);
    if (pull !== undefined && pull.state === "OPEN") {
      pull.headOid = oid;
      pull.checks = "PENDING";
    }
    fake.commits.push({
      branch,
      headline: input.message.headline,
      additions: input.fileChanges.additions.map((addition): string => addition.path),
      deletions: input.fileChanges.deletions.map((deletion): string => deletion.path),
    });
    const file: FakeBlob | undefined = tree.get(String(variables.path));
    return Response.json({ data: { createCommitOnBranch: { commit: { oid, file: file === undefined ? null : { oid: file.oid } } } } });
  }
  if (body.query.includes("mutation BlogAutoMerge(")) {
    const pull: FakePull | undefined = fake.pulls.find((candidate: FakePull): boolean => candidate.id === variables.id);
    if (pull === undefined || fake.flags.autoMergeError !== null) {
      return Response.json({ data: { enablePullRequestAutoMerge: null }, errors: [{ type: "UNPROCESSABLE", message: fake.flags.autoMergeError ?? "unknown pull request" }] });
    }
    pull.autoMerge = true;
    return Response.json({ data: { enablePullRequestAutoMerge: { pullRequest: { autoMergeRequest: { enabledAt: "2026-10-15T12:00:00Z" } } } } });
  }
  return Response.json({ errors: [{ message: `unknown query ${body.query.slice(0, 40)}` }] });
}

/** REST: file reads, branch creation and deletion, opening and closing pull requests. */
async function rest(fake: FakeGithub, request: Request): Promise<Response> {
  const url: URL = new URL(request.url);
  const path: string = decodeURIComponent(request.url.slice(repoRoot.length).split("?")[0] ?? "");
  if (request.method === "GET" && request.url.startsWith(contentsPrefix)) {
    const ref: string = url.searchParams.get("ref") ?? "";
    const blob: FakeBlob | undefined = fake.branches.has(ref) ? branchTree(fake, ref).get(path.slice("contents/".length)) : undefined;
    return blob === undefined
      ? Response.json({ message: "Not Found" }, { status: 404 })
      : Response.json({ type: "file", sha: blob.oid, encoding: "base64", content: githubBase64(blob.bytes) });
  }
  if (request.method === "POST" && path === "git/refs") {
    const body: { ref: string; sha: string } = await request.json();
    const branch: string = body.ref.replace(/^refs\/heads\//, "");
    if (fake.branches.has(branch)) {
      return Response.json({ message: "Reference already exists" }, { status: 422 });
    }
    fake.branches.set(branch, body.sha);
    return Response.json({ ref: body.ref, object: { sha: body.sha } }, { status: 201 });
  }
  if (request.method === "DELETE" && path.startsWith("git/refs/heads/")) {
    const branch: string = path.slice("git/refs/heads/".length);
    return fake.branches.delete(branch) ? new Response(null, { status: 204 }) : Response.json({ message: "Reference does not exist" }, { status: 422 });
  }
  if (request.method === "POST" && path === "pulls") {
    const body: { title: string; head: string; base: string; body: string } = await request.json();
    expect(body.base).toBe("main");
    expect(body.body).toContain("Auto-merge (squash) is enabled");
    const number: number = fake.pulls.length + 1;
    const pull: FakePull = {
      id: `PR_node_${number}`,
      number,
      branch: body.head,
      title: body.title,
      state: "OPEN",
      headOid: fake.branches.get(body.head) ?? "",
      autoMerge: false,
      checks: null,
      updatedAt: `2026-10-15T12:00:${String(number).padStart(2, "0")}Z`,
    };
    fake.pulls.push(pull);
    return Response.json(
      { node_id: pull.id, number, html_url: `https://github.com/${repository}/pull/${number}`, title: pull.title, updated_at: pull.updatedAt, head: { sha: pull.headOid } },
      { status: 201 },
    );
  }
  const closing: RegExpExecArray | null = /^pulls\/(\d+)$/.exec(path);
  if (request.method === "PATCH" && closing !== null) {
    const pull: FakePull | undefined = fake.pulls.find((candidate: FakePull): boolean => candidate.number === Number(closing[1]));
    if (pull === undefined) {
      return Response.json({ message: "Not Found" }, { status: 404 });
    }
    pull.state = "CLOSED";
    pull.autoMerge = false;
    return Response.json({ state: "closed", updated_at: "2026-10-15T12:30:00Z" });
  }
  return Response.json({ message: "Not Found" }, { status: 404 });
}

/** Fake GitHub REST and GraphQL; every request must carry the token and a user agent. */
async function stubGithub(harness: Harness): Promise<FakeGithub> {
  const fake: FakeGithub = {
    trees: new Map(),
    branches: new Map(),
    pulls: [],
    commits: [],
    flags: { staleOnce: false, finishBeforeNextCommit: false, autoMergeError: null },
  };
  fake.trees.set("0".repeat(40), new Map());
  fake.branches.set("main", "0".repeat(40));
  harness.stub("https://api.github.com/", async (request: Request): Promise<Response> => {
    if (request.headers.get("authorization") !== `Bearer ${token}` || request.headers.get("user-agent") === null) {
      return Response.json({ message: "Bad credentials" }, { status: 401 });
    }
    return new URL(request.url).pathname === "/graphql" ? graphql(fake, request) : rest(fake, request);
  });
  return fake;
}

/** Yazı dosyası (deponun biçiminde). */
function postFile(title: string, published: string, draft: boolean): string {
  return `---\ntitle: ${title}\ndescription: A description that is long enough for the content schema to accept it here.\nauthor: Senol Dogan\npublished: ${published}\ndraft: ${String(draft)}\n---\n\nFirst paragraph.\n\n## Heading\n\nMore text.\n`;
}

/** Geçerli bir kayıt gövdesi. */
function input(fields: Partial<Record<string, string | boolean | null>>): object {
  return {
    title: "Weekly notes: what we shipped",
    description: 'A "quoted" summary: colons, # hashes and quotes stay safe inside the front matter.',
    author: "Senol Dogan",
    published: "2026-10-22",
    updated: null,
    cover: null,
    draft: false,
    body: "Intro paragraph.\n\n## Section\n\n- one\n- two\n",
    sha: null,
    ...fields,
  };
}

/**
 * Sahte WebP: RIFF/WEBP imzası, VP8L parçası ve verilen boyut (yalnızca başlık geçerlidir; sunucu görseli çözmez).
 * `length` toplam bayt sayısıdır.
 */
function fakeWebp(width: number, height: number, length: number): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(length);
  const view: DataView = new DataView(bytes.buffer);
  bytes.set(utf8("RIFF"), 0);
  view.setUint32(4, length - 8, true);
  bytes.set(utf8("WEBPVP8L"), 8);
  view.setUint32(16, length - 20, true);
  bytes[20] = 0x2f;
  view.setUint32(21, (width - 1) | ((height - 1) << 14), true);
  return bytes;
}

/** Görsel yükleme gövdesi. */
function imageBody(bytes: Uint8Array): object {
  return { data: base64Encode(bytes) };
}

describe("blog yazılarının dosya biçimi", () => {
  it("sitedeki gerçek yazılar okunur", () => {
    for (const [slug, text] of [
      ["meeting-notes-on-mac-without-a-bot", realPostNoBot],
      ["record-teams-zoom-google-meet-on-mac", realPostRecording],
      ["turn-a-meeting-into-a-task-list", realPostTasks],
    ] as const) {
      const parsed = parseBlogFile(slug, text);
      expect(parsed.frontMatter.draft).toBe(false);
      expect(parsed.frontMatter.published).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(parsed.body.length).toBeGreaterThan(500);
    }
  });

  it("yazılan ön bilgi okunduğunda aynı değerleri verir (tırnak, iki nokta, diyez, ters bölü, Unicode)", () => {
    const frontMatter = { title: 'Say "hi": #1 \\ tips — ok', description: "x".repeat(60), author: "Şenol Doğan", published: "2026-11-05", updated: null, cover: null, draft: true };
    const text: string = serializeBlogPost(frontMatter, "\n\nBody line\n\n");
    expect(text.startsWith('---\ntitle: "Say \\"hi\\": #1 \\\\ tips — ok"\n')).toBe(true);
    expect(text).not.toContain("updated:");
    expect(text).not.toContain("cover:");
    expect(parseBlogFile("x", text)).toEqual({ frontMatter, body: "Body line" });
  });

  it("isteğe bağlı updated ve cover yazılır ve okunur; geçersiz değer, boş alan ya da yayından önceki updated reddedilir", () => {
    const frontMatter = { title: "A post with a cover", description: "y".repeat(60), author: "Senol Dogan", published: "2026-10-01", updated: "2026-10-12", cover: "ocean" as const, draft: false };
    const text: string = serializeBlogPost(frontMatter, "Body");
    expect(text).toContain("\npublished: 2026-10-01\nupdated: 2026-10-12\ncover: ocean\ndraft: false\n");
    expect(parseBlogFile("x", text)).toEqual({ frontMatter, body: "Body" });
    for (const broken of [
      text.replace("cover: ocean", "cover: teal"),
      text.replace("cover: ocean", "cover:"),
      text.replace("updated: 2026-10-12", "updated: 2026-09-30"),
      text.replace("updated: 2026-10-12", "updated: 12 Oct 2026"),
    ]) {
      expect(() => parseBlogFile("x", broken)).toThrow(/invalid fields/);
    }
  });

  it("kapak aileleri sitenin film aileleriyle aynıdır", () => {
    expect([...blogCoverPalettes]).toEqual([...filmPalettes]);
  });

  it("WebP boyutu VP8L, VP8 ve VP8X başlıklarından okunur; WebP olmayan ya da eksik dosya 415", () => {
    expect(webpDimensions(fakeWebp(1600, 900, 64))).toEqual({ width: 1600, height: 900 });
    const lossy: Uint8Array = fakeWebp(1, 1, 64);
    lossy.set(utf8("VP8 "), 12);
    new DataView(lossy.buffer).setUint16(26, 1200, true);
    new DataView(lossy.buffer).setUint16(28, 630, true);
    expect(webpDimensions(lossy)).toEqual({ width: 1200, height: 630 });
    const extended: Uint8Array = fakeWebp(1, 1, 64);
    extended.set(utf8("VP8X"), 12);
    extended.set([0x3f, 0x06, 0x00, 0x83, 0x03, 0x00], 24);
    expect(webpDimensions(extended)).toEqual({ width: 1600, height: 900 });
    for (const broken of [utf8("\u0089PNG\r\n\u001a\n".padEnd(64, "x")), fakeWebp(10, 10, 64).slice(0, 40)]) {
      expect(() => webpDimensions(broken)).toThrow(expect.objectContaining({ code: "unsupported_media_type" }));
    }
  });
});

interface ChangeBody {
  readonly number: number;
  readonly url: string;
  readonly slug: string;
  readonly title: string;
  readonly state: string;
  readonly autoMerge: boolean;
  readonly checks: string;
  readonly updatedAt: string;
}

interface PostBody {
  readonly slug: string;
  readonly title: string;
  readonly description: string;
  readonly author: string;
  readonly published: string;
  readonly updated: string | null;
  readonly cover: string | null;
  readonly draft: boolean;
  readonly status: string;
  readonly sha: string;
  readonly body: string;
  readonly change: ChangeBody | null;
}

interface SavedBody extends PostBody {
  readonly autoMergeError: string | null;
}

interface ListBody {
  readonly today: string;
  readonly posts: ReadonlyArray<Omit<PostBody, "body">>;
  readonly changes: readonly ChangeBody[];
}

interface ImageBody {
  readonly path: string;
  readonly sha: string;
  readonly bytes: number;
  readonly width: number;
  readonly height: number;
  readonly change: ChangeBody;
  readonly autoMergeError: string | null;
}

interface DeletedBody {
  readonly images: number;
  readonly change: ChangeBody;
  readonly autoMergeError: string | null;
}

/** Test setup: fake GitHub, the test's own admin (the per-user rate limit does not accumulate across tests) and env. */
interface Setup {
  readonly harness: Harness;
  readonly admin: Session;
  readonly fake: FakeGithub;
  /** Env with the admin and the token. */
  readonly env: Env;
  /** Same admin, no token. */
  readonly noTokenEnv: Env;
}

async function setup(): Promise<Setup> {
  const harness: Harness = await defaultHarness();
  const fake: FakeGithub = await stubGithub(harness);
  const subject: string = `blog-admin-${randomId()}`;
  const admin: Session = await signInWithGoogle(harness, subject);
  return {
    harness,
    admin,
    fake,
    env: envWith({ ADMIN_IDENTITIES: `google:${subject}`, GITHUB_BLOG_TOKEN: token }),
    noTokenEnv: envWith({ ADMIN_IDENTITIES: `google:${subject}` }),
  };
}

function call(context: Setup, session: Session, method: string, path: string, json: object | null): Promise<Response> {
  return context.harness.call(req(method, path, { token: session.accessToken, env: context.env, json }));
}

/** Outbound GitHub requests. */
function githubRequests(harness: Harness): Request[] {
  return harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://api.github.com/"));
}

/** Warning log lines written while `run` runs. */
async function warningsDuring(run: () => Promise<void>): Promise<string[]> {
  const warnings = vi.spyOn(console, "warn");
  try {
    await run();
    return warnings.mock.calls.map((args: unknown[]): string => String(args[0]));
  } finally {
    warnings.mockRestore();
  }
}

const branchOne: string = "blog/weekly-notes-20261015120000";

describe("panel pull request helpers", () => {
  it("branch names carry the slug and a UTC timestamp, and only panel branches give a slug back", () => {
    expect(blogBranchName("weekly-notes", new Date(Date.UTC(2026, 9, 15, 12, 0, 5, 250)))).toBe("blog/weekly-notes-20261015120005");
    expect(blogBranchSlug("blog/weekly-notes-20261015120005")).toBe("weekly-notes");
    expect(blogBranchSlug("blog/post-2-20261015120005")).toBe("post-2");
    for (const other of ["blog/weekly-notes", "fix/blog-admin", "blog/Bad_Slug-20261015120005", "blog/x-2026101512000"]) {
      expect(blogBranchSlug(other)).toBeNull();
    }
  });

  it("checks state maps GitHub's rollup; two open pull requests for one post are a conflict", () => {
    expect(["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED", null].map(blogChecksState)).toEqual(["passing", "failing", "failing", "pending", "pending", "none"]);
    const change = { number: 1, url: "u", slug: "a", title: "t", state: "open" as const, autoMerge: true, checks: "none" as const, updatedAt: "x" };
    expect(pendingPullRequestOf([change, { ...change, slug: "b", number: 2 }, { ...change, number: 3, state: "merged" as const }], "a")).toEqual(change);
    expect(pendingPullRequestOf([change], "c")).toBeNull();
    expect(() => pendingPullRequestOf([change, { ...change, number: 4 }], "a")).toThrow(expect.objectContaining({ code: "blog_conflict" }));
  });
});

describe("/v1/admin/blog", () => {
  it("list: posts newest first with status and version; non-.md files are ignored; no pull requests yet", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    await seedMain(fake, {
      [`${postDirectory}older-post.md`]: postFile("An older live post", "2026-10-01", false),
      [`${postDirectory}today-post.md`]: postFile("A post going live today", "2026-10-15", false),
      [`${postDirectory}next-week.md`]: postFile("A post scheduled for later", "2026-10-22", false),
      [`${postDirectory}draft-post.md`]: postFile("A draft dated in the past", "2026-10-02", true),
      [`${postDirectory}README.txt`]: "not a post",
    });
    const response: Response = await call(context, admin, "GET", "/v1/admin/blog/posts", null);
    expect(response.status).toBe(200);
    const body: ListBody = await response.json<ListBody>();
    expect(body.today).toBe("2026-10-15");
    expect(body.changes).toEqual([]);
    expect(body.posts.map((post) => [post.slug, post.status, post.change])).toEqual([
      ["next-week", "scheduled", null],
      ["today-post", "live", null],
      ["draft-post", "draft", null],
      ["older-post", "live", null],
    ]);
    expect(body.posts[0]).toEqual({
      slug: "next-week",
      title: "A post scheduled for later",
      description: "A description that is long enough for the content schema to accept it here.",
      author: "Senol Dogan",
      published: "2026-10-22",
      updated: null,
      cover: null,
      draft: false,
      status: "scheduled",
      sha: branchTree(fake, "main").get(`${postDirectory}next-week.md`)?.oid,
      change: null,
    });
  });

  it("an empty folder is an empty list; an unreadable post is an explicit error", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const empty: ListBody = await (await call(context, admin, "GET", "/v1/admin/blog/posts", null)).json<ListBody>();
    expect(empty.posts).toEqual([]);
    await seedMain(fake, { [`${postDirectory}tagged.md`]: postFile("A post with an extra field", "2026-10-01", false).replace("draft: false\n", "draft: false\ntags: [a]\n") });
    const body = await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts", null), 500, "blog_post_invalid");
    expect(body.error.message).toContain("web/src/content/blog/tagged.md");
  });

  it("one post: front matter, body and version; a missing post is 404, an invalid slug 400", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    await seedMain(fake, { [`${postDirectory}today-post.md`]: postFile("A post going live today", "2026-10-15", false) });
    const response: Response = await call(context, admin, "GET", "/v1/admin/blog/posts/today-post", null);
    expect(response.status).toBe(200);
    const post: PostBody = await response.json<PostBody>();
    expect(post).toMatchObject({ slug: "today-post", title: "A post going live today", status: "live", draft: false, updated: null, cover: null, change: null });
    expect(post.sha).toBe(branchTree(fake, "main").get(`${postDirectory}today-post.md`)?.oid);
    expect(post.body).toBe("First paragraph.\n\n## Heading\n\nMore text.");
    await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts/missing-post", null), 404, "not_found");
    await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts/Bad_Slug", null), 400, "bad_request");
  });

  it("new post: lands on a blog/<slug>-<time> branch in a pull request with auto-merge (squash), never on main", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const mainBefore: string | undefined = fake.branches.get("main");
    const response: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}));
    expect(response.status).toBe(201);
    const post: SavedBody = await response.json<SavedBody>();
    expect(post).toMatchObject({ slug: "weekly-notes", status: "scheduled", published: "2026-10-22", body: "Intro paragraph.\n\n## Section\n\n- one\n- two", autoMergeError: null });
    expect(post.change).toEqual({
      number: 1,
      url: "https://github.com/senoldogan-labs/AI-Notepad/pull/1",
      slug: "weekly-notes",
      title: "blog: Weekly notes: what we shipped",
      state: "open",
      autoMerge: true,
      checks: "none",
      updatedAt: "2026-10-15T12:00:01Z",
    });
    expect(fake.branches.get("main")).toBe(mainBefore);
    expect(fileText(fake, "main", `${postDirectory}weekly-notes.md`)).toBeNull();
    expect(fileText(fake, branchOne, `${postDirectory}weekly-notes.md`)).toBe(
      [
        "---",
        'title: "Weekly notes: what we shipped"',
        'description: "A \\"quoted\\" summary: colons, # hashes and quotes stay safe inside the front matter."',
        'author: "Senol Dogan"',
        "published: 2026-10-22",
        "draft: false",
        "---",
        "",
        "Intro paragraph.",
        "",
        "## Section",
        "",
        "- one",
        "- two",
        "",
      ].join("\n"),
    );
    expect(post.sha).toBe(branchTree(fake, branchOne).get(`${postDirectory}weekly-notes.md`)?.oid);
    expect(fake.commits).toEqual([{ branch: branchOne, headline: "blog: Weekly notes: what we shipped", additions: [`${postDirectory}weekly-notes.md`], deletions: [] }]);
    expect(fake.pulls.map((pull) => [pull.number, pull.branch, pull.state, pull.autoMerge])).toEqual([[1, branchOne, "OPEN", true]]);

    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ title: "Another post with the same slug" })), 409, "blog_post_exists");
    expect(fake.commits).toHaveLength(1);
  });

  it("later writes for the post go to its open pull request; list and read show that version with the pull request", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const created: SavedBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ draft: true }))).json<SavedBody>();
    const updated: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: created.sha, published: "2026-10-15", body: "Rewritten." }));
    expect(updated.status).toBe(200);
    const post: SavedBody = await updated.json<SavedBody>();
    expect(post).toMatchObject({ status: "live", body: "Rewritten.", change: { number: 1, state: "open", autoMerge: true, checks: "pending" } });
    expect(post.sha).not.toBe(created.sha);
    expect(fake.pulls).toHaveLength(1);
    expect(fake.commits.map((commit) => commit.branch)).toEqual([branchOne, branchOne]);

    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: created.sha })), 409, "blog_conflict");
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/never-created", input({ sha: created.sha })), 409, "blog_conflict");
    expect(fake.commits).toHaveLength(2);

    const list: ListBody = await (await call(context, admin, "GET", "/v1/admin/blog/posts", null)).json<ListBody>();
    expect(list.posts).toHaveLength(1);
    expect(list.posts[0]).toMatchObject({ slug: "weekly-notes", status: "live", sha: post.sha, change: { number: 1, state: "open", checks: "pending" } });
    expect(list.changes.map((change) => [change.number, change.state])).toEqual([[1, "open"]]);
    const read: PostBody = await (await call(context, admin, "GET", "/v1/admin/blog/posts/weekly-notes", null)).json<PostBody>();
    expect(read).toMatchObject({ body: "Rewritten.", sha: post.sha, change: { number: 1 } });
  });

  it("after the pull request merges, the post reads from main and the next save opens a new pull request", async () => {
    const context: Setup = await setup();
    const { harness, admin, fake } = context;
    const created: SavedBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ published: "2026-10-01" }))).json<SavedBody>();
    await mergePull(fake, 1);
    const list: ListBody = await (await call(context, admin, "GET", "/v1/admin/blog/posts", null)).json<ListBody>();
    expect(list.posts.map((post) => [post.slug, post.status, post.sha, post.change])).toEqual([["weekly-notes", "live", created.sha, null]]);
    expect(list.changes.map((change) => [change.number, change.state])).toEqual([[1, "merged"]]);

    harness.clock.nowMs += 600_000;
    const edited: SavedBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ published: "2026-10-01", sha: created.sha, cover: "violet", updated: "2026-10-14" }))).json<SavedBody>();
    expect(edited).toMatchObject({ cover: "violet", updated: "2026-10-14", change: { number: 2, state: "open", autoMerge: true } });
    expect(fake.pulls[1]?.branch).toBe("blog/weekly-notes-20261015121000");
    expect(fileText(fake, "blog/weekly-notes-20261015121000", `${postDirectory}weekly-notes.md`)).toContain("\npublished: 2026-10-01\nupdated: 2026-10-14\ncover: violet\ndraft: false\n");
    expect(fileText(fake, "main", `${postDirectory}weekly-notes.md`)).not.toMatch(/cover:/);
  });

  it("auto-merge that GitHub refuses is reported with the open pull request, not as published", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    fake.flags.autoMergeError = "Auto merge is not allowed for this repository";
    let response: Response | null = null;
    const lines: string[] = await warningsDuring(async (): Promise<void> => {
      response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}));
    });
    const saved: Response = response ?? new Response();
    expect(saved.status).toBe(201);
    const post: SavedBody = await saved.json<SavedBody>();
    expect(post.autoMergeError).toBe("Auto merge is not allowed for this repository");
    expect(post.change).toMatchObject({ number: 1, state: "open", autoMerge: false });
    expect(lines.some((line: string): boolean => line.includes('"event":"blog_auto_merge_failed"'))).toBe(true);

    fake.flags.autoMergeError = null;
    const again: SavedBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: post.sha, body: "Second try." }))).json<SavedBody>();
    expect(again).toMatchObject({ autoMergeError: null, change: { number: 1, autoMerge: true } });
  });

  it("delete: a merged post and its images are removed in one commit through a pull request; old version 409, missing 404, no version 400", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    await seedMain(fake, {
      [`${postDirectory}weekly-notes.md`]: postFile("Weekly notes for deletion", "2026-10-01", false),
      [`${imageDirectory}weekly-notes/chart.webp`]: fakeWebp(10, 10, 64),
      [`${imageDirectory}weekly-notes/screen.webp`]: fakeWebp(10, 10, 64),
      [`${imageDirectory}other-post/keep.webp`]: fakeWebp(10, 10, 64),
    });
    const sha: string = branchTree(fake, "main").get(`${postDirectory}weekly-notes.md`)?.oid ?? "";
    await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"f".repeat(40)}`, null), 409, "blog_conflict");
    await expectError(await call(context, admin, "DELETE", "/v1/admin/blog/posts/weekly-notes", null), 400, "bad_request");
    const response: Response = await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${sha}`, null);
    expect(response.status).toBe(200);
    const deleted: DeletedBody = await response.json<DeletedBody>();
    expect(deleted).toMatchObject({ images: 2, autoMergeError: null, change: { number: 1, state: "open", autoMerge: true, title: "blog: remove weekly-notes" } });
    expect(fake.commits.at(-1)).toEqual({
      branch: branchOne,
      headline: "blog: remove weekly-notes",
      additions: [],
      deletions: [`${postDirectory}weekly-notes.md`, `${imageDirectory}weekly-notes/chart.webp`, `${imageDirectory}weekly-notes/screen.webp`],
    });
    expect(fileText(fake, "main", `${postDirectory}weekly-notes.md`)).not.toBeNull();
    const list: ListBody = await (await call(context, admin, "GET", "/v1/admin/blog/posts", null)).json<ListBody>();
    expect(list.posts.map((post) => [post.slug, post.change?.number ?? null])).toEqual([["weekly-notes", 1]]);
    await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts/weekly-notes", null), 404, "not_found");
    await mergePull(fake, 1);
    expect([...branchTree(fake, "main").keys()]).toEqual([`${imageDirectory}other-post/keep.webp`]);
    await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${sha}`, null), 404, "not_found");
  });

  it("delete: a post that exists only in its open pull request closes that pull request and removes its branch", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const created: SavedBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}))).json<SavedBody>();
    const response: Response = await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${created.sha}`, null);
    expect(response.status).toBe(200);
    expect(await response.json<DeletedBody>()).toMatchObject({ images: 0, change: { number: 1, state: "closed", autoMerge: false } });
    expect(fake.pulls[0]?.state).toBe("CLOSED");
    expect(fake.branches.has(branchOne)).toBe(false);
    expect(fake.commits).toHaveLength(1);
    const list: ListBody = await (await call(context, admin, "GET", "/v1/admin/blog/posts", null)).json<ListBody>();
    expect(list.posts).toEqual([]);
    expect(list.changes.map((change) => [change.number, change.state])).toEqual([[1, "closed"]]);
  });

  it("the branch moving under a write, or the pull request merging before the commit lands, re-plans the write with a warning", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    const created: SavedBody = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}))).json<SavedBody>();
    fake.flags.staleOnce = true;
    let stale: SavedBody | null = null;
    const staleLines: string[] = await warningsDuring(async (): Promise<void> => {
      stale = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: created.sha, body: "After a stale head." }))).json<SavedBody>();
    });
    expect(stale).toMatchObject({ body: "After a stale head.", change: { number: 1 } });
    expect(staleLines.some((line: string): boolean => line.includes('"event":"blog_write_retry"') && line.includes("stale_branch"))).toBe(true);

    context.harness.clock.nowMs += 60_000;
    fake.flags.finishBeforeNextCommit = true;
    const latest: string = (stale as SavedBody | null)?.sha ?? "";
    let landed: SavedBody | null = null;
    const finishedLines: string[] = await warningsDuring(async (): Promise<void> => {
      landed = await (await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: latest, body: "After the merge." }))).json<SavedBody>();
    });
    expect(finishedLines.some((line: string): boolean => line.includes('"event":"blog_write_retry"') && line.includes("pull_request_finished"))).toBe(true);
    expect(landed).toMatchObject({ body: "After the merge.", change: { number: 2, state: "open" } });
    expect(fileText(fake, "blog/weekly-notes-20261015120100", `${postDirectory}weekly-notes.md`)).toContain("After the merge.");
  });

  it("two open pull requests for one post refuse writes until one is merged or closed", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}));
    fake.pulls.push({ ...(fake.pulls[0] as FakePull), id: "PR_node_9", number: 9, branch: "blog/weekly-notes-20261015120009" });
    const body = await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ sha: "a".repeat(40) })), 409, "blog_conflict");
    expect(body.error.message).toContain("#1, #9");
  });

  it("image: committed to the post's pull request (201, with path, size and pull request); same name 409", async () => {
    const context: Setup = await setup();
    const { admin, fake } = context;
    await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({}));
    const image: Uint8Array = fakeWebp(1600, 900, 2048);
    const response: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes/images/team-board.webp", imageBody(image));
    expect(response.status).toBe(201);
    const saved: ImageBody = await response.json<ImageBody>();
    expect(saved).toMatchObject({ path: "/blog/weekly-notes/team-board.webp", bytes: 2048, width: 1600, height: 900, change: { number: 1 }, autoMergeError: null });
    const blob: FakeBlob | undefined = branchTree(fake, branchOne).get(`${imageDirectory}weekly-notes/team-board.webp`);
    expect(saved.sha).toBe(blob?.oid);
    expect(blob?.bytes).toEqual(image);
    expect(fake.commits.at(-1)).toEqual({ branch: branchOne, headline: "blog: image weekly-notes/team-board.webp", additions: [`${imageDirectory}weekly-notes/team-board.webp`], deletions: [] });
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes/images/team-board.webp", imageBody(image)), 409, "blog_image_exists");
    expect(fake.commits).toHaveLength(2);
    expect(fake.pulls).toHaveLength(1);
  });

  it("image validation: no post is 404; name, signature, size and width are refused before GitHub", async () => {
    const context: Setup = await setup();
    const { harness, admin, fake } = context;
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/never-saved/images/chart.webp", imageBody(fakeWebp(10, 10, 64))), 404, "not_found");
    expect(fake.pulls).toEqual([]);
    expect([...fake.branches.keys()]).toEqual(["main"]);
    const before: number = githubRequests(harness).length;
    const path: string = "/v1/admin/blog/posts/weekly-notes/images";
    await expectError(await call(context, admin, "PUT", `${path}/Chart.webp`, imageBody(fakeWebp(10, 10, 64))), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `${path}/chart.png`, imageBody(fakeWebp(10, 10, 64))), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `${path}/${"a".repeat(76)}.webp`, imageBody(fakeWebp(10, 10, 64))), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, imageBody(utf8("\u0089PNG\r\n\u001a\n".padEnd(64, "x")))), 415, "unsupported_media_type");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, imageBody(fakeWebp(1601, 900, 64))), 400, "invalid_body");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, imageBody(fakeWebp(1600, 900, blogImageMaxBytes + 1))), 413, "payload_too_large");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, { data: "not base64!" }), 400, "invalid_body");
    await expectError(await call(context, admin, "PUT", `${path}/chart.webp`, { data: base64Encode(fakeWebp(10, 10, 64)), extra: 1 }), 400, "invalid_body");
    expect(githubRequests(harness)).toHaveLength(before);
  });

  it("validation: the content schema's limits, slug, dates, empty or long body, multi-line title; GitHub is not called", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    const cases: ReadonlyArray<Partial<Record<string, string | boolean | null>>> = [
      { title: "Too short" },
      { title: "x".repeat(91) },
      { description: "x".repeat(49) },
      { description: "x".repeat(171) },
      { author: "" },
      { published: "2026-02-30" },
      { published: "22 Oct 2026" },
      { updated: "2026-10-21" },
      { updated: "2026-13-01" },
      { cover: "teal" },
      { body: "   \n " },
      { body: "x".repeat(60_001) },
      { title: "A title that has\na line break" },
      { sha: "not-a-sha" },
      { extra: "field" },
    ];
    for (const fields of cases) {
      await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input(fields)), 400, "invalid_body");
    }
    const { cover: _cover, ...withoutCover } = input({}) as Record<string, unknown>;
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", withoutCover), 400, "invalid_body");
    await expectError(await call(context, admin, "PUT", "/v1/admin/blog/posts/two--dashes", input({})), 400, "bad_request");
    await expectError(await call(context, admin, "PUT", `/v1/admin/blog/posts/${"a".repeat(81)}`, input({})), 400, "bad_request");
    expect(githubRequests(harness)).toHaveLength(0);
    const longest: Response = await call(context, admin, "PUT", "/v1/admin/blog/posts/weekly-notes", input({ body: "é".repeat(60_000) }));
    expect(longest.status).toBe(201);
  });

  it("every blog endpoint answers a non-admin with a plain 403", async () => {
    const context: Setup = await setup();
    const { harness } = context;
    const user: Session = await signIn(harness);
    const requests: ReadonlyArray<readonly [string, string, object | null]> = [
      ["GET", "/v1/admin/blog/posts", null],
      ["GET", "/v1/admin/blog/posts/weekly-notes", null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes", input({})],
      ["DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"a".repeat(40)}`, null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes/images/chart.webp", imageBody(fakeWebp(10, 10, 64))],
    ];
    for (const [method, path, json] of requests) {
      await expectError(await call(context, user, method, path, json), 403, "forbidden");
    }
    expect(githubRequests(harness)).toHaveLength(0);
  });

  it("without a token every blog endpoint is 503 blog_unavailable", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    const requests: ReadonlyArray<readonly [string, string, object | null]> = [
      ["GET", "/v1/admin/blog/posts", null],
      ["GET", "/v1/admin/blog/posts/weekly-notes", null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes", input({})],
      ["DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"a".repeat(40)}`, null],
      ["PUT", "/v1/admin/blog/posts/weekly-notes/images/chart.webp", imageBody(fakeWebp(10, 10, 64))],
    ];
    for (const [method, path, json] of requests) {
      await expectError(await harness.call(req(method, path, { token: admin.accessToken, env: context.noTokenEnv, json })), 503, "blog_unavailable");
    }
  });

  it("a GitHub refusal is 502 upstream_rejected (body logged, token not); 5xx is retried 3 times with a warning", async () => {
    const context: Setup = await setup();
    const { harness, admin } = context;
    let attempts: number = 0;
    const lines: string[] = await warningsDuring(async (): Promise<void> => {
      harness.stub("https://api.github.com/graphql", async (): Promise<Response> => Response.json({ message: "Resource not accessible by personal access token" }, { status: 403 }));
      await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts", null), 502, "upstream_rejected");
      await expectError(await call(context, admin, "DELETE", `/v1/admin/blog/posts/weekly-notes?sha=${"a".repeat(40)}`, null), 502, "upstream_rejected");
      harness.stub("https://api.github.com/graphql", async (): Promise<Response> => {
        attempts += 1;
        return new Response("unavailable", { status: 503 });
      });
      await expectError(await call(context, admin, "GET", "/v1/admin/blog/posts/weekly-notes", null), 502, "upstream_unavailable");
    });
    expect(attempts).toBe(3);
    expect(lines.some((line: string): boolean => line.includes('"event":"github_request_failed"') && line.includes("Resource not accessible"))).toBe(true);
    expect(lines.filter((line: string): boolean => line.includes('"event":"upstream_retry"') && line.includes('"service":"github"'))).toHaveLength(2);
    expect(lines.some((line: string): boolean => line.includes(token))).toBe(false);
  });

  it("CORS preflight allows PUT", async () => {
    const context: Setup = await setup();
    const { harness } = context;
    const preflight: Response = await harness.call(
      req("OPTIONS", "/v1/admin/blog/posts/weekly-notes", { headers: { origin: "http://localhost:8788", "access-control-request-method": "PUT" } }),
    );
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("access-control-allow-methods")).toContain("PUT");
  });
});
