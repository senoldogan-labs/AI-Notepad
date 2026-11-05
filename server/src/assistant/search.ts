/**
 * In-memory search over decrypted search texts (the `search` MCP tool). There is no full-text index: an index would
 * hold the text in plaintext and survive deletion (design review). The tool decrypts the user's newest search texts
 * and ranks them with a small BM25: terms are literal (no operators), at most `maxQueryTerms`, and a term of three or
 * more characters also matches word prefixes at half weight, which covers inflected Turkish and Finnish words.
 */

/** Most terms a query keeps. */
export const maxQueryTerms: number = 8;
/** Longest kept term. */
const maxTermChars: number = 64;
const k1: number = 1.2;
const b: number = 0.75;
const prefixWeight: number = 0.5;

/** A document to rank. */
export interface SearchDocument {
  readonly id: string;
  readonly text: string;
}

/** A ranked hit. */
export interface SearchHit {
  readonly id: string;
  readonly score: number;
}

/** Lower-cased words without diacritics (letters and digits of any script). Pure function. */
export function tokenize(text: string): string[] {
  return (
    text
      .normalize("NFKD")
      .replace(/\p{M}+/gu, "")
      .toLowerCase()
      .match(/[\p{L}\p{N}]+/gu) ?? []
  );
}

/** The query as at most `maxQueryTerms` unique literal terms. Pure function. */
export function sanitizeQuery(query: string): string[] {
  const terms: string[] = [];
  for (const token of tokenize(query)) {
    const term: string = token.slice(0, maxTermChars);
    if (!terms.includes(term)) {
      terms.push(term);
    }
    if (terms.length === maxQueryTerms) {
      break;
    }
  }
  return terms;
}

/** How often a term occurs in the tokens: exact matches count 1, prefix matches `prefixWeight`. Pure function. */
function termFrequency(tokens: readonly string[], term: string): number {
  let frequency: number = 0;
  for (const token of tokens) {
    if (token === term) {
      frequency += 1;
    } else if (term.length >= 3 && token.startsWith(term)) {
      frequency += prefixWeight;
    }
  }
  return frequency;
}

/** Documents with a positive BM25 score for the terms, best first (ties by input order). Pure function. */
export function rankDocuments(documents: readonly SearchDocument[], terms: readonly string[]): SearchHit[] {
  if (documents.length === 0 || terms.length === 0) {
    return [];
  }
  const tokenized: string[][] = documents.map((document: SearchDocument): string[] => tokenize(document.text));
  const averageLength: number = Math.max(1, tokenized.reduce((sum: number, tokens: string[]): number => sum + tokens.length, 0) / tokenized.length);
  const frequencies: number[][] = tokenized.map((tokens: string[]): number[] => terms.map((term: string): number => termFrequency(tokens, term)));
  const documentFrequency: number[] = terms.map((_term: string, index: number): number =>
    frequencies.filter((row: number[]): boolean => (row[index] ?? 0) > 0).length,
  );
  const hits: Array<SearchHit & { readonly order: number }> = [];
  documents.forEach((document: SearchDocument, order: number): void => {
    const length: number = tokenized[order]?.length ?? 0;
    let score: number = 0;
    terms.forEach((_term: string, index: number): void => {
      const frequency: number = frequencies[order]?.[index] ?? 0;
      if (frequency === 0) {
        return;
      }
      const df: number = documentFrequency[index] ?? 0;
      const idf: number = Math.log(1 + (documents.length - df + 0.5) / (df + 0.5));
      score += (idf * frequency * (k1 + 1)) / (frequency + k1 * (1 - b + (b * length) / averageLength));
    });
    if (score > 0) {
      hits.push({ id: document.id, score, order });
    }
  });
  return hits
    .sort((left, right): number => right.score - left.score || left.order - right.order)
    .map(({ id, score }): SearchHit => ({ id, score }));
}
