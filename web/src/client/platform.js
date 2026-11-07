// @ts-check
// Marks iPhones and iPads before the first paint: `<html data-platform="ios">`. Runs inline in <head> (Base.astro; the CSP
// allows it by the sha256 hash computed at build, like theme.js), so the calls to action swap without a layout shift:
// global.css hides `.not-ios` (the Mac download) and shows `.ios-only` (the App Store badge) on these devices. iPadOS
// Safari reports itself as a Mac; its touch screen (more than one touch point) tells it apart. Not compiled: checked
// through JSDoc types.

(() => {
  const userAgent = navigator.userAgent;
  const isIos = /iPhone|iPad|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && navigator.maxTouchPoints > 1);
  if (isIos) {
    document.documentElement.dataset["platform"] = "ios";
  }
})();
