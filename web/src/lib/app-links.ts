// Uygulamayı açan bağlantılar (`gistsmith://…`). Uygulamadaki ayrıştırıcı
// Packages/AINotepadCore/Sources/AINotepadCore/Meeting/AppLinks.swift'tir; kimlik kuralı onunla ve sunucudaki
// `normalizedMeetingId` ile aynıdır.

/** Davet parçası: 16 baytlık davet kimliği ve 32 baytlık sır, base64url (Swift `sharedFolderInvite(text:)`). */
const invitePattern: RegExp = /^#[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}$/;

/**
 * Davet sayfasının adresindeki parçadan (`#<davet>.<sır>`) uygulamada katılma ekranını açan adres
 * (`gistsmith://join#<davet>.<sır>`); parça bu biçimde değilse null. Parça hiçbir sunucuya gitmez. Saf fonksiyondur.
 */
export function appJoinLink(hash: string): string | null {
  return invitePattern.test(hash) ? `gistsmith://join${hash}` : null;
}

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
