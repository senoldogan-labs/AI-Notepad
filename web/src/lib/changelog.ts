// Sürüm geçmişi (/changelog): Gistsmith'in yayın notları (docs/release-notes/gistsmith-<sürüm>.md, uygulamaların
// güncelleme penceresinde ve GitHub sürümünde gösterilen metnin aynısı) yeniden eskiye, yayın günüyle. Yayın günü
// docs/release-notes/release-dates.json'dadır (sürüm → YYYY-AA-GG, GitHub sürümünün yayımlandığı UTC günü): yayın
// derlemesi sığ bir checkout'tur (git geçmişi yok) ve notlar dosyası Sparkle'a olduğu gibi gittiği için içine tarih
// yazılmaz. Notu olup günü olmayan (ya da günü olup notu olmayan) sürüm derlemeyi durdurur. Bu dosya saftır; dosyaları
// okuyan kısım `changelog-source.ts`'tedir.
import { Marked, type Token } from "marked";

/** Yayın notunun dosya adı kalıbı: `gistsmith-<büyük>.<küçük>.<yama>.md` (AI-Notepad'in notları sayılmaz). */
const notesFilePattern: RegExp = /(?:^|\/)gistsmith-(\d+)\.(\d+)\.(\d+)\.md$/;

/** Yayın günü kalıbı (YYYY-AA-GG). */
const isoDatePattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;

/** Sürüm numarası, karşılaştırılabilir parçalarıyla. */
export interface ReleaseVersion {
  /** "0.2.4" */
  readonly text: string;
  readonly parts: readonly [number, number, number];
}

/** Sürüm geçmişinde bir sürüm. */
export interface ChangelogEntry {
  readonly version: string;
  /** Yayın günü (YYYY-AA-GG, UTC). */
  readonly date: string;
  /** Sayfadaki çapa (`v0-2-4`): bir sürüme doğrudan bağlantı. */
  readonly anchor: string;
  /** Notların HTML'i; başlıklar bir düzey aşağı (notun `##`'i sayfada h3). */
  readonly html: string;
}

/** Dosya yolundan Gistsmith sürümü; kalıba uymuyorsa null. Saf fonksiyondur. */
export function releaseVersionOf(path: string): ReleaseVersion | null {
  const match: RegExpExecArray | null = notesFilePattern.exec(path);
  if (match === null) {
    return null;
  }
  const parts: readonly [number, number, number] = [Number(match[1]), Number(match[2]), Number(match[3])];
  return { text: parts.join("."), parts };
}

/** Yeniden eskiye sıralama karşılaştırıcısı. Saf fonksiyondur. */
export function newestFirst(a: ReleaseVersion, b: ReleaseVersion): number {
  for (let index: number = 0; index < 3; index += 1) {
    const difference: number = (b.parts[index] ?? 0) - (a.parts[index] ?? 0);
    if (difference !== 0) {
      return difference;
    }
  }
  return 0;
}

/** Notların Markdown'ını HTML'e çevirir; başlıklar bir düzey aşağı iner (sayfada sürüm başlığı h2'dir). Saf fonksiyondur. */
export function releaseNotesHtml(markdown: string): string {
  const parser: Marked = new Marked({
    gfm: true,
    async: false,
    walkTokens(token: Token): void {
      if (token.type === "heading") {
        token.depth = Math.min(token.depth + 1, 6);
      }
    },
  });
  return parser.parse(markdown, { async: false });
}

/**
 * Sürüm geçmişi: notlar (yol → Markdown) ve yayın günleri (sürüm → YYYY-AA-GG) eşleşmeli. Gistsmith notu olmayan
 * dosyalar atlanır; günü olmayan not, notu olmayan gün ya da biçimi bozuk gün hata verir (derleme durur). Saf
 * fonksiyondur.
 */
export function changelogEntries(notes: Readonly<Record<string, string>>, dates: Readonly<Record<string, string>>): ChangelogEntry[] {
  const releases: { readonly version: ReleaseVersion; readonly markdown: string }[] = Object.entries(notes).flatMap(
    ([path, markdown]: [string, string]): { readonly version: ReleaseVersion; readonly markdown: string }[] => {
      const version: ReleaseVersion | null = releaseVersionOf(path);
      return version === null ? [] : [{ version, markdown }];
    },
  );
  const versions: ReadonlySet<string> = new Set(releases.map((release): string => release.version.text));
  const orphanDates: string[] = Object.keys(dates).filter((version: string): boolean => !versions.has(version));
  if (orphanDates.length > 0) {
    throw new Error(`release-dates.json'da notu olmayan sürümler: ${orphanDates.join(", ")} (docs/release-notes/gistsmith-<sürüm>.md yok)`);
  }
  return [...releases]
    .sort((a, b): number => newestFirst(a.version, b.version))
    .map((release): ChangelogEntry => {
      const date: string | undefined = dates[release.version.text];
      if (date === undefined || !isoDatePattern.test(date)) {
        throw new Error(
          `docs/release-notes/release-dates.json'da ${release.version.text} için YYYY-AA-GG biçiminde yayın günü yok; gelen: ${JSON.stringify(date ?? null)}`,
        );
      }
      return {
        version: release.version.text,
        date,
        anchor: `v${release.version.text.replaceAll(".", "-")}`,
        html: releaseNotesHtml(release.markdown),
      };
    });
}
