// Sürüm geçmişinin kaynağı: depodaki yayın notları ve yayın günleri derlemede okunur (Vite `import.meta.glob`, dosyalar
// web/'in dışında, docs/release-notes'ta). Yeni bir sürümün notu eklenince sayfa bir sonraki derlemede kendiliğinden
// güncellenir; yayın günü aynı sürüm PR'ında release-dates.json'a yazılır (bkz. `changelog.ts`).
import { type ChangelogEntry, changelogEntries } from "./changelog";
import releaseDates from "../../../docs/release-notes/release-dates.json";

const notes: Readonly<Record<string, string>> = import.meta.glob<string>("../../../docs/release-notes/gistsmith-*.md", {
  query: "?raw",
  import: "default",
  eager: true,
});

/** Yeniden eskiye Gistsmith sürümleri, notları ve yayın günleriyle. */
export const changelog: readonly ChangelogEntry[] = changelogEntries(notes, releaseDates);
