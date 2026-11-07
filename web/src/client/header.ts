// Üst çubuk: sekmenin oturumu sahiplenilir (kopya sekme, bkz. session.ts); oturum varsa "Giriş yap" bağlantıları
// hesap sayfasına gider ve "Hesap" yazar. Dar ekrandaki menü (`<details class="menu">`) Escape'le, dışına tıklanınca ya
// da sayfa kaydırılınca kapanır (açık menünün arkasında sayfa kaymaz gibi görünmesin).
import { MissingElementError, dataValue, element } from "./dom";
import { claimTabSession, hasSession } from "./session";

/** Oturum varsa giriş bağlantılarını hesap bağlantısına çevirir. */
function linkAccount(header: HTMLElement): void {
  if (!hasSession()) {
    return;
  }
  const href: string = dataValue(header, "accountHref");
  const label: string = dataValue(header, "accountLabel");
  const current: boolean = window.location.pathname === href;
  for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-session-link]")) {
    link.href = href;
    link.textContent = label;
    // Bağlantı artık hesap sayfasına gider: "geçerli sayfa" işareti yalnızca hesap sayfasındayken kalır (ör. /sign-in'de
    // derlemede konan işaret silinir).
    if (current) {
      link.setAttribute("aria-current", "page");
    } else {
      link.removeAttribute("aria-current");
    }
  }
}

/** Açık menüyü Escape'le (odak menü düğmesine döner) ve menünün dışına tıklanınca kapatır. */
function closeMenuOnDismiss(header: HTMLElement): void {
  const menu: HTMLDetailsElement | null = header.querySelector<HTMLDetailsElement>("details.menu");
  const summary: HTMLElement | null = menu?.querySelector<HTMLElement>("summary") ?? null;
  if (menu === null || summary === null) {
    throw new MissingElementError("Üst çubukta details.menu ya da summary yok.");
  }
  document.addEventListener("keydown", (event: KeyboardEvent): void => {
    if (event.key === "Escape" && menu.open) {
      menu.open = false;
      summary.focus();
    }
  });
  document.addEventListener("click", (event: MouseEvent): void => {
    if (menu.open && event.target instanceof Node && !menu.contains(event.target)) {
      menu.open = false;
    }
  });
  // Scrolling the page more than a few pixels closes the open menu.
  const scrollTolerance: number = 24;
  let openedAt: number = window.scrollY;
  menu.addEventListener("toggle", (): void => {
    openedAt = window.scrollY;
  });
  window.addEventListener(
    "scroll",
    (): void => {
      if (menu.open && Math.abs(window.scrollY - openedAt) > scrollTolerance) {
        menu.open = false;
      }
    },
    { passive: true },
  );
}

/** Sayfa kaydırılınca üst çubuk yüzen hapa döner (`is-scrolled`); en üstte sayfanın üstünde durur. */
function floatOnScroll(header: HTMLElement): void {
  const update = (): void => {
    header.classList.toggle("is-scrolled", window.scrollY > 12);
  };
  update();
  window.addEventListener("scroll", update, { passive: true });
}

/** Davranışları bağlar; hesap bağlantısı sekmenin oturumu sahiplenildikten sonra (kopya sekmede oturum silinir). */
async function main(): Promise<void> {
  const header: HTMLElement = element("site-header", HTMLElement);
  closeMenuOnDismiss(header);
  floatOnScroll(header);
  await claimTabSession();
  linkAccount(header);
}

main().catch((error: unknown): void => {
  console.error("header_failed", { error: error instanceof Error ? error.message : String(error) });
});
