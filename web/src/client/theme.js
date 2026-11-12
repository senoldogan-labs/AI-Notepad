// @ts-check
// Açık/koyu tema ve renk paleti (Warm Ember varsayılan, Classic seçilebilir; alt bilgideki düğmeler `data-palette-choice`,
// seçim localStorage'da `gistsmith.palette`). <head> içinde satır içi betik olarak çalışır (Base.astro; CSP bu betiğe derlemede hesaplanan sha256
// özetiyle izin verir; ayrı istek ilk boyamayı geciktirirdi): ilk boyamadan önce `<html data-theme>` yazılır, sayfa
// yanlış temada yanıp sönmez. Kullanıcı seçim yapmadıysa sistem tercihi izlenir; düğmeyle yapılan seçim localStorage'da kalır. Tema değişince `gistsmith:themechange` olayı yayılır
// (Turnstile parçacığı temayı buradan alır). Tarayıcı çubuğunun rengi (`<meta name="theme-color">`) de seçilen temaya
// uyar; bu yüzden Base.astro'da meta etiketleri bu betikten önce gelir. Derlenmez: TypeScript denetimi JSDoc
// tipleriyle yapılır.

(() => {
  /** Tema adı. @typedef {"light" | "dark"} Theme */

  /** Renk paleti: "ember" (varsayılan, Warm Ember) ya da "classic" (sitenin ilk paleti). @typedef {"ember" | "classic"} Palette */

  const storageKey = "gistsmith.theme";
  const paletteKey = "gistsmith.palette";
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const root = document.documentElement;
  // Tarayıcı çubuğunun rengi palete ve temaya göre; global.css `--bg` ile aynı kalmalı.
  /** @type {Record<Palette, Record<Theme, string>>} */
  const barColors = {
    ember: { light: "#f6f0e7", dark: "#100e0d" },
    classic: { light: "#ffffff", dark: "#000000" },
  };

  /**
   * Saklanan palet; yoksa ya da depolama kapalıysa varsayılan "ember" (depolama kapalıysa uyarı yazılır).
   * @returns {Palette}
   */
  function storedPalette() {
    try {
      return window.localStorage.getItem(paletteKey) === "classic" ? "classic" : "ember";
    } catch (error) {
      console.warn("palette_storage_unavailable", { error: error instanceof Error ? error.message : String(error) });
      return "ember";
    }
  }

  /** @returns {Palette} */
  function currentPalette() {
    return root.dataset["palette"] === "classic" ? "classic" : "ember";
  }

  /**
   * Paleti sayfaya yazar ve palet düğmelerini günceller.
   * @param {Palette} palette
   */
  function applyPalette(palette) {
    root.dataset["palette"] = palette;
    for (const button of document.querySelectorAll("[data-palette-choice]")) {
      button.setAttribute("aria-pressed", String(button.getAttribute("data-palette-choice") === palette));
    }
  }

  /**
   * Palet seçimini saklar. Saklanamazsa seçim yalnızca bu sayfada geçerlidir (uyarı yazılır).
   * @param {Palette} palette
   */
  function rememberPalette(palette) {
    try {
      window.localStorage.setItem(paletteKey, palette);
    } catch (error) {
      console.warn("palette_storage_unavailable", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  /**
   * Saklanan seçim; yoksa null. Depolama kapalıysa (ör. tarayıcı ayarı) uyarı yazılır ve sistem tercihi kullanılır.
   * @returns {Theme | null}
   */
  function storedTheme() {
    try {
      const value = window.localStorage.getItem(storageKey);
      return value === "light" || value === "dark" ? value : null;
    } catch (error) {
      console.warn("theme_storage_unavailable", { error: error instanceof Error ? error.message : String(error) });
      return null;
    }
  }

  /** @returns {Theme} */
  function systemTheme() {
    return darkQuery.matches ? "dark" : "light";
  }

  /**
   * Tarayıcı çubuğunun rengini paletin ve temanın sayfa zeminine çeker (iki `theme-color` etiketi de).
   * @param {Theme} theme
   */
  function paintBar(theme) {
    for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
      meta.setAttribute("content", barColors[currentPalette()][theme]);
    }
  }

  /**
   * Temayı sayfaya yazar; tarayıcı çubuğunun rengini ve düğmeleri günceller. İki `theme-color` etiketi de (sistem
   * tercihine göre seçilenler) aynı renge çekilir, böylece elle seçilen tema sistem teması yerine geçer.
   * @param {Theme} theme
   */
  function apply(theme) {
    root.dataset["theme"] = theme;
    paintBar(theme);
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      button.setAttribute("aria-pressed", String(theme === "dark"));
    }
    document.dispatchEvent(new CustomEvent("gistsmith:themechange", { detail: theme }));
  }

  /**
   * Kullanıcının seçimini saklar. Saklanamazsa seçim yalnızca bu sayfada geçerlidir (uyarı yazılır).
   * @param {Theme} theme
   */
  function remember(theme) {
    try {
      window.localStorage.setItem(storageKey, theme);
    } catch (error) {
      console.warn("theme_storage_unavailable", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  applyPalette(storedPalette());
  apply(storedTheme() ?? systemTheme());
  // Whether the visitor chose a theme: kept in memory too, so a choice that could not be stored still holds on this page.
  let chosenOnPage = false;

  // Seçim yapılmadıysa sistem teması değişince sayfa da değişir.
  darkQuery.addEventListener("change", () => {
    if (!chosenOnPage && storedTheme() === null) {
      apply(systemTheme());
    }
  });

  document.addEventListener("DOMContentLoaded", () => {
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      button.setAttribute("aria-pressed", String(root.dataset["theme"] === "dark"));
      button.addEventListener("click", () => {
        /** @type {Theme} */
        const next = root.dataset["theme"] === "dark" ? "light" : "dark";
        // Renk geçişi yalnızca düğmeyle değişimde ve kısa süre açık (sayfa yüklenirken geçiş olmaz).
        root.classList.add("theme-switching");
        window.setTimeout(() => root.classList.remove("theme-switching"), 400);
        chosenOnPage = true;
        remember(next);
        apply(next);
      });
    }
    for (const button of document.querySelectorAll("[data-palette-choice]")) {
      button.addEventListener("click", () => {
        /** @type {Palette} */
        const next = button.getAttribute("data-palette-choice") === "classic" ? "classic" : "ember";
        root.classList.add("theme-switching");
        window.setTimeout(() => root.classList.remove("theme-switching"), 400);
        rememberPalette(next);
        applyPalette(next);
        paintBar(root.dataset["theme"] === "dark" ? "dark" : "light");
      });
    }
    applyPalette(currentPalette());
  });
})();
