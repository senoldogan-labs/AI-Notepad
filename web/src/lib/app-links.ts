// Uygulamayı açan bağlantılar (`gistsmith://…`). Uygulamadaki ayrıştırıcı
// Packages/AINotepadCore/Sources/AINotepadCore/Meeting/AppLinks.swift'tir; kimlik kuralı onunla ve sunucudaki
// `normalizedMeetingId` ile aynıdır.

/** Uygulamaların toplantı kimliği: harf ya da rakamla başlar; harf, rakam, `-` ve `_`; en çok 64 karakter. */
const meetingIdPattern: RegExp = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

/**
 * Toplantı bağlantısı sayfasının adresinden (`/m/<kimlik>`, sonda `/` olabilir) uygulamada toplantıyı açan adres
 * (`gistsmith://meeting/<kimlik>`); adres bu biçimde değilse ya da kimlik kurala uymazsa null. Saf fonksiyondur.
 */
export function appMeetingLink(pathname: string): string | null {
  const match: RegExpExecArray | null = /^\/m\/([^/]+)\/?$/.exec(pathname);
  const id: string | undefined = match?.[1];
  return id !== undefined && meetingIdPattern.test(id) ? `gistsmith://meeting/${id}` : null;
}
