// Vite'ın `?raw` içe aktarımı: dosyanın metni (blog testleri sitedeki gerçek yazıları okur).
declare module "*.md?raw" {
  const text: string;
  export default text;
}

// Wrangler yapılandırmasının metni (asistan bağlamaları ve yer tutucu kimlikler denetlenir; bkz. assistantInert.test.ts).
declare module "*.jsonc?raw" {
  const text: string;
  export default text;
}
