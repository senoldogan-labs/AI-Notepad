import { describe, expect, it } from "vitest";
import {
  AssistantCryptoError,
  AssistantKeyringError,
  type AssistantKeyring,
  openField,
  openUserFields,
  parseAssistantKeyring,
  sealField,
  sealedKeyId,
} from "../src/assistant/crypto";
import { type MeetingProjection, meetingIndex, noteMarkdown, searchText } from "../src/assistant/projection";
import { rankDocuments, sanitizeQuery, tokenize } from "../src/assistant/search";
import { isAllowedRegistrationRedirect, presentClient, sanitizeClientName } from "../src/mcp/clients";
import { escapeHtml } from "../src/mcp/html";
import { grantMaxAgeMs, refreshIdleSeconds, refreshLifetimeSeconds } from "../src/mcp/grants";
import { decodeCursor, encodeCursor, ToolError } from "../src/mcp/tools";

const keyA: string = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
const keyB: string = btoa(String.fromCharCode(...new Uint8Array(32).fill(9)));
const user: string = "11111111-1111-4111-8111-111111111111";
const otherUser: string = "22222222-2222-4222-8222-222222222222";
const meeting: string = "33333333-3333-4333-8333-333333333333";
const otherMeeting: string = "44444444-4444-4444-8444-444444444444";
const plaintext: Uint8Array = new TextEncoder().encode('{"summary":"quarterly budget"}');

describe("assistant crypto", () => {
  const keyring: AssistantKeyring = parseAssistantKeyring(`1:${keyA}`);

  it("round-trips a field and names the key it was sealed with", async () => {
    const sealed: Uint8Array = await sealField(keyring, user, meeting, "note", plaintext);
    expect(new TextDecoder().decode(sealed.subarray(0, 4))).toBe("GSA1");
    expect(sealedKeyId(sealed)).toBe(1);
    expect(await openField(keyring, user, meeting, "note", sealed)).toEqual(plaintext);
    // A fresh nonce every time.
    expect(await sealField(keyring, user, meeting, "note", plaintext)).not.toEqual(sealed);
  });

  it("refuses a tampered blob, another user, another meeting and another field", async () => {
    const sealed: Uint8Array = await sealField(keyring, user, meeting, "note", plaintext);
    const tampered: Uint8Array = sealed.slice();
    tampered[tampered.length - 1] = (tampered[tampered.length - 1] ?? 0) ^ 1;
    await expect(openField(keyring, user, meeting, "note", tampered)).rejects.toBeInstanceOf(AssistantCryptoError);
    await expect(openField(keyring, otherUser, meeting, "note", sealed)).rejects.toBeInstanceOf(AssistantCryptoError);
    await expect(openField(keyring, user, otherMeeting, "note", sealed)).rejects.toBeInstanceOf(AssistantCryptoError);
    await expect(openField(keyring, user, meeting, "index", sealed)).rejects.toBeInstanceOf(AssistantCryptoError);
    await expect(openField(keyring, user, meeting, "note", sealed.subarray(0, 20))).rejects.toBeInstanceOf(AssistantCryptoError);
  });

  it("rotates: new writes use the first key, old objects still open, unknown key ids fail", async () => {
    const old: Uint8Array = await sealField(keyring, user, meeting, "index", plaintext);
    const rotated: AssistantKeyring = parseAssistantKeyring(`2:${keyB},1:${keyA}`);
    const fresh: Uint8Array = await sealField(rotated, user, meeting, "index", plaintext);
    expect(sealedKeyId(fresh)).toBe(2);
    expect(await openField(rotated, user, meeting, "index", old)).toEqual(plaintext);
    expect(await openField(rotated, user, meeting, "index", fresh)).toEqual(plaintext);
    await expect(openField(keyring, user, meeting, "index", fresh)).rejects.toBeInstanceOf(AssistantCryptoError);
    // The same key id with other key material is a wrong key, not a silent success.
    await expect(openField(parseAssistantKeyring(`1:${keyB}`), user, meeting, "index", old)).rejects.toBeInstanceOf(AssistantCryptoError);
  });

  it("opens many fields of one user with mixed key ids, and fails on any bad one", async () => {
    const rotated: AssistantKeyring = parseAssistantKeyring(`2:${keyB},1:${keyA}`);
    const items = [
      { meetingId: meeting, sealed: await sealField(keyring, user, meeting, "index", plaintext) },
      { meetingId: otherMeeting, sealed: await sealField(rotated, user, otherMeeting, "index", plaintext) },
    ];
    expect(await openUserFields(rotated, user, "index", items)).toEqual([plaintext, plaintext]);
    await expect(openUserFields(rotated, otherUser, "index", items)).rejects.toBeInstanceOf(AssistantCryptoError);
    await expect(openUserFields(rotated, user, "index", [{ meetingId: meeting, sealed: items[1]?.sealed ?? new Uint8Array(0) }])).rejects.toBeInstanceOf(AssistantCryptoError);
  });

  it("parses only well-formed keyrings", () => {
    for (const bad of [undefined, "", "abc", `0:${keyA}`, `256:${keyA}`, `1:${keyA},1:${keyB}`, "1:c2hvcnQ=", "1:%%%%"]) {
      expect(() => parseAssistantKeyring(bad)).toThrow(AssistantKeyringError);
    }
    expect(parseAssistantKeyring(` 3:${keyA} , 1:${keyB}`).currentKeyId).toBe(3);
  });
});

const projection: MeetingProjection = {
  title: "Budget review",
  startedAt: "2026-11-02T09:00:00+02:00",
  durationSec: 3720,
  folder: "Finance",
  attendees: ["Ada", "Linus"],
  language: "en",
  note: {
    title: "Q4 budget",
    summary: "We cut the travel budget and moved hiring to January.",
    decisions: ["Travel budget down 20%"],
    tasks: [
      { owner: "Sen", description: "Send the revised forecast", dueDate: "Friday", isMine: true, done: false },
      { owner: "Linus", description: "Update the hiring plan", dueDate: null, isMine: false, done: true },
    ],
    outline: [{ startSec: 65, title: "Travel", summary: "Cut by a fifth." }],
    glossary: [{ term: "FTE", meaning: "Full-time equivalent" }],
  },
  myNotes: "Ask about the offsite.",
};

describe("assistant projection", () => {
  it("builds the index with own tasks only and a bounded search text", () => {
    const index = meetingIndex(projection);
    expect(index.title).toBe("Budget review");
    expect(index.myTasks).toEqual([{ owner: "Sen", description: "Send the revised forecast", dueDate: "Friday", done: false }]);
    expect(index.searchText).toContain("travel budget");
    expect(index.searchText).toContain("Travel");
    expect(searchText({ ...projection, note: { ...projection.note!, summary: "x".repeat(10_000) } }).length).toBe(4000);
    expect(meetingIndex({ ...projection, title: " ", note: null }).title).toBe("Untitled meeting");
  });

  it("renders the note as Markdown with every section", () => {
    const markdown: string = noteMarkdown(projection);
    expect(markdown).toContain("# Budget review");
    expect(markdown).toContain("- Duration: 1 h 02 min");
    expect(markdown).toContain("- [ ] Sen: Send the revised forecast (due Friday) [mine]");
    expect(markdown).toContain("- [x] Linus: Update the hiring plan");
    expect(markdown).toContain("- 1:05 Travel: Cut by a fifth.");
    expect(markdown).toContain("## My notes");
    expect(noteMarkdown({ ...projection, note: null, myNotes: null })).toContain("No note was written");
  });
});

describe("assistant search", () => {
  it("keeps at most 8 unique literal terms, without operators or diacritics", () => {
    expect(sanitizeQuery('"budget" OR (travel) AND -hiring * Ünal ünal')).toEqual(["budget", "or", "travel", "and", "hiring", "unal"]);
    expect(sanitizeQuery("a b c d e f g h i j")).toHaveLength(8);
    expect(sanitizeQuery("*** --- ()")).toEqual([]);
    expect(tokenize("Toplantı-notları 2026")).toEqual(["toplantı", "notları", "2026"]);
  });

  it("ranks matching documents and matches word prefixes", () => {
    const documents = [
      { id: "a", text: "budget budget travel" },
      { id: "b", text: "hiring plan" },
      { id: "c", text: "budgeting for travel" },
    ];
    const hits = rankDocuments(documents, ["budget"]);
    expect(hits.map((hit) => hit.id)).toEqual(["a", "c"]);
    expect(rankDocuments(documents, ["nothing"])).toEqual([]);
    expect(rankDocuments([], ["budget"])).toEqual([]);
  });
});

describe("MCP client presentation", () => {
  it("verifies only exact allowlisted callbacks, whatever the registered name", () => {
    expect(presentClient("https://claude.ai/api/mcp/auth_callback", "Totally Not Claude")).toEqual({ kind: "verified", name: "Claude", redirectHost: "claude.ai" });
    expect(presentClient("https://chatgpt.com/connector_platform_oauth_redirect", null).kind).toBe("verified");
    expect(presentClient("https://claude.ai/api/mcp/auth_callback/x", "Claude").kind).toBe("unverified");
    expect(presentClient("http://127.0.0.1:33418/callback", "Claude Code")).toEqual({ kind: "local", name: "Claude Code", redirectHost: "127.0.0.1" });
  });

  it("strips bidi, invisible and look-alike characters and caps names at 40 characters", () => {
    expect(sanitizeClientName("Cl‮aude​ Bank")).toBe("Cl aude Bank");
    expect(sanitizeClientName("Сlaude")).toBe("laude"); // Cyrillic С
    expect(sanitizeClientName("x".repeat(60))).toHaveLength(40);
    expect(sanitizeClientName("‮⁦")).toBe("Unnamed app");
    expect(escapeHtml('<img src=x onerror="a">')).not.toContain("<");
  });

  it("refuses remote http redirect URIs at registration", () => {
    expect(isAllowedRegistrationRedirect("https://client.example/cb")).toBe(true);
    expect(isAllowedRegistrationRedirect("http://localhost:8787/callback")).toBe(true);
    expect(isAllowedRegistrationRedirect("cursor://anysphere.cursor-mcp/oauth/callback")).toBe(true);
    expect(isAllowedRegistrationRedirect("http://client.example/cb")).toBe(false);
    expect(isAllowedRegistrationRedirect("javascript:alert(1)")).toBe(false);
    expect(isAllowedRegistrationRedirect("not a url")).toBe(false);
  });
});

describe("MCP grant lifetimes and cursors", () => {
  it("slides 30 days idle and never past 180 days", () => {
    const created: number = Date.UTC(2026, 0, 1);
    expect(refreshLifetimeSeconds(created, created + 1000)).toBe(refreshIdleSeconds);
    expect(refreshLifetimeSeconds(created, created + grantMaxAgeMs - 10 * 86_400_000)).toBe(10 * 86_400);
    expect(refreshLifetimeSeconds(created, created + grantMaxAgeMs - 30_000)).toBeNull();
  });

  it("round-trips cursors and refuses forged ones", () => {
    const cursor = { s: 1_700_000_000_000, m: meeting };
    expect(decodeCursor(encodeCursor(cursor))).toEqual(cursor);
    expect(() => decodeCursor("not-a-cursor!")).toThrow(ToolError);
    expect(() => decodeCursor(btoa('{"s":"x"}'))).toThrow(ToolError);
  });
});
