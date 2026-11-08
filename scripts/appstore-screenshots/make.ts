// App Store ekran görüntülerini üretir: iPhone uygulamasını Simülatör için derler, örnek toplantıları (seeder/) App Store
// çekimlerine ayrılmış bir Simülatör aygıtına yükler, config.ts'teki her sahneyi başlatma argümanlarıyla açıp çeker ve
// ana setin her çekimini başlıklı, çerçeveli bir görsele dönüştürür (compose.ts). Tam çalıştırma özel ürün sayfalarının
// çekimlerini (`pageScenes`) de raw/'a çeker; onları marketing.ts düzenler. Her veri seti (`seed`) aygıtı temizleyip
// kendi verisiyle açar. Hesap gerekmez: uygulama Debug tanıtım moduyla
// (`--tanitim`) açılır, veri diskten okunur, canlı kayıt sahnesi uygulamanın Debug örnek kaydıdır (`--ornek-kayit`).
// Abonelik ekranı (`paywall`) paketleri RevenueCat'ten, fiyatları App Store sandbox'ından okur (ağ gerekir).
//
// Kullanım (repo kökünden):
//   npm --prefix scripts/appstore-screenshots run make                         # tüm set
//   npm --prefix scripts/appstore-screenshots run make -- --scene live --scene note
//   npm --prefix scripts/appstore-screenshots run make -- --raw-only <sahne>   # yalnız ham çekim (abonelik inceleme görseli;
//                                                                             # birden çok --raw-only aynı açılışta çekilir)
//   npm --prefix scripts/appstore-screenshots run make -- --compose-only       # son ham çekimlerden yalnız yeniden düzenle
//   npm --prefix scripts/appstore-screenshots run make -- --device duo         # iPhone Duo'nun iç ekranı (2007×2853; iOS
//                                                                             # 27.1+ Simülatörü, aygıt açık; bkz. config.ts)
//
// Çıktı (.build/appstore-screenshots/, repoya girmez):
//   raw/<sahne>.png              Simülatör çekimi (1320×2868); ana set ve özel ürün sayfaları
//   6.9/<sıra>-<sahne>.png       1320×2868, sRGB, saydamlıksız (App Store 6.9")
//   6.5/<sıra>-<sahne>.png       1284×2778 (App Store 6.5")
//   6.3/<sıra>-<sahne>.png       1206×2622 (App Store 6.3")
//   raw-only/<sahne>.png         `--raw-only`: ham çekim, sRGB, saydamlıksız, aygıt çözünürlüğünde
//   previews/<sahne>.jpg, previews/overview.jpg   küçük önizlemeler ve tüm setin paftası
//   --device duo: raw-duo/, duo/<sıra>-<sahne>.png (2007×2853), raw-only-duo/, previews-duo/
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { parseArgs } from "node:util";
import sharp, { type ChannelStats, type Metadata, type Stats } from "sharp";
import { ChromeRenderer, contactSheet, flattenToSrgbPng, previewJpeg, sceneHtml } from "./compose.ts";
import {
  app,
  askConversationPlaceholder,
  configProblems,
  type DeviceTarget,
  devices,
  meetingPlaceholder,
  type OutputSize,
  pageScenes,
  palettes,
  type RawScene,
  rawScenes,
  type Scene,
  scenes,
  type SeedSet,
  statusBarOverride,
} from "./config.ts";
import { runCommand } from "./process.ts";
import { Simulator } from "./simulator.ts";

/** Ayar dosyasında ya da komut satırında hata. */
class ConfigError extends Error {
  override readonly name: string = "ConfigError";
}

/** Çekim beklenen ölçüde değil. */
class CaptureError extends Error {
  override readonly name: string = "CaptureError";
}

const repoRoot: string = resolve(import.meta.dirname, "../..");
const outputRoot: string = join(repoRoot, ".build/appstore-screenshots");
const fontPath: string = join(repoRoot, "web/src/assets/fonts/InterVariable-latin.woff2");
const seederPackage: string = join(repoRoot, "scripts/appstore-screenshots/seeder");
const packageResolved: string = "Packages/AINotepadCore/Package.resolved";
const previewWidth: number = 660;
/** Isınma açılışından sonra bekleme (ms). */
const warmUpMs: number = 8000;
/** Boş ekran denemesi ve eşiği (kanal başına ortalama standart sapma, 0–255). */
const captureAttempts: number = 3;
const blankStdev: number = 4;

/** Tohumlayıcının yazdığı kimlikler (seeder/: `SeedManifest`). */
interface SeedManifest {
  readonly meeting: string;
  readonly askConversation: string;
}

/** Komut satırından seçilen iş. */
type Job =
  | { readonly kind: "full"; readonly target: DeviceTarget; readonly captures: readonly RawScene[]; readonly scenes: readonly Scene[]; readonly chrome: string }
  | { readonly kind: "raw-only"; readonly target: DeviceTarget; readonly scenes: readonly RawScene[] }
  | { readonly kind: "compose-only"; readonly target: DeviceTarget; readonly scenes: readonly Scene[]; readonly chrome: string };

/** `--device` değerinin çekim hattı; bilinmeyen değerde `ConfigError`. Saf fonksiyondur. */
function deviceTarget(id: string): DeviceTarget {
  switch (id) {
    case "iphone":
      return devices.iphone;
    case "duo":
      return devices.duo;
    default:
      throw new ConfigError(`Bilinmeyen --device: ${id}. Değerler: iphone, duo`);
  }
}

/** Kimliği verilen sahne; yoksa bilinen kimliklerle `ConfigError`. Saf fonksiyondur. */
function findScene<T extends RawScene>(list: readonly T[], id: string): T {
  const scene: T | undefined = list.find((candidate: T) => candidate.id === id);
  if (scene === undefined) {
    throw new ConfigError(`Bilinmeyen sahne: ${id}. Sahneler: ${list.map((s: T) => s.id).join(", ")}`);
  }
  return scene;
}

/**
 * Yerel saati sabah 10'a yakın tutan saat dilimi (`Etc/GMT±n`; işaret POSIX'te terstir): "bugün"ün toplantıları sabah
 * olur ve hep geçmiştedir. Saf fonksiyondur.
 */
function morningTimeZone(utcHour: number): string {
  const offset: number = ((10 - utcHour + 36) % 24) - 12;
  return offset >= 0 ? `Etc/GMT-${offset}` : `Etc/GMT+${-offset}`;
}

/**
 * Durum çubuğunun saati: uygulamanın saat dilimindeki şimdiki saat ("10:04"). Sabit bir saat ("9:41") ana ekrandaki
 * takvime göre göreli saatlerle ("Now 10:12") çelişirdi. Saf fonksiyondur.
 */
function statusBarClock(now: Date, timeZone: string): string {
  return new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", hour12: true, timeZone })
    .format(now)
    .replace(/\s?[AP]M$/u, "");
}

/** Yer tutucunun değeri: tohumlayıcının kimlikleri; yer tutucu değilse kendisi. Saf fonksiyondur. */
function resolvedArgument(arg: string, manifest: SeedManifest): string {
  switch (arg) {
    case meetingPlaceholder:
      return manifest.meeting;
    case askConversationPlaceholder:
      return manifest.askConversation;
    default:
      return arg;
  }
}

/** Sahnenin argümanları: ortak argümanlar ve sahneninkiler, yer tutucular çözülmüş. Saf fonksiyondur. */
function launchArguments(common: readonly string[], scene: RawScene, manifest: SeedManifest): readonly string[] {
  return [...common, ...scene.launchArgs.map((arg: string) => resolvedArgument(arg, manifest))];
}

/** Komut satırını işe çevirir. */
function parseJob(argv: readonly string[]): Job {
  const { values } = parseArgs({
    args: [...argv],
    options: {
      chrome: { type: "string" },
      scene: { type: "string", multiple: true },
      "raw-only": { type: "string", multiple: true },
      "compose-only": { type: "boolean" },
      device: { type: "string", default: "iphone" },
    },
    strict: true,
    allowPositionals: false,
  });
  const target: DeviceTarget = deviceTarget(values.device);
  const rawOnly: readonly string[] | undefined = values["raw-only"];
  if (rawOnly !== undefined) {
    if (values.scene !== undefined || values["compose-only"] === true) {
      throw new ConfigError("--raw-only tek başına kullanılır (--scene ve --compose-only ile değil)");
    }
    return { kind: "raw-only", target, scenes: rawOnly.map((id: string) => findScene<RawScene>([...scenes, ...pageScenes, ...rawScenes], id)) };
  }
  const chrome: string | undefined = values.chrome;
  if (chrome === undefined || chrome === "") {
    throw new ConfigError("Eksik: --chrome <Chrome yolu> (npm run make bunu verir)");
  }
  if (values["compose-only"] === true) {
    const selected: readonly Scene[] = values.scene === undefined ? scenes : values.scene.map((id: string) => findScene(scenes, id));
    return { kind: "compose-only", target, scenes: selected, chrome };
  }
  // Tam çalıştırma ana seti ve özel ürün sayfalarının çekimlerini alır; yalnız ana set burada düzenlenir.
  const captures: readonly RawScene[] =
    values.scene === undefined ? [...scenes, ...pageScenes] : values.scene.map((id: string) => findScene<RawScene>([...scenes, ...pageScenes], id));
  const ids: ReadonlySet<string> = new Set<string>(captures.map((scene: RawScene) => scene.id));
  return { kind: "full", target, captures, scenes: scenes.filter((scene: Scene) => ids.has(scene.id)), chrome };
}

/** `git status` boşsa true: dosyada kaydedilmemiş değişiklik yok. */
async function isClean(path: string): Promise<boolean> {
  return (await runCommand("git", ["status", "--porcelain", "--", path], repoRoot, {})).stdout.trim() === "";
}

/**
 * Uygulamayı Simülatör için derler. Xcode derlerken paketin Package.resolved dosyasını yeniden yazar: derlemeden önce
 * temizse eski haline döndürülür (önceden değişmişse sahibinin değişikliğidir, dokunulmaz).
 */
async function buildApp(udid: string): Promise<string> {
  const resolvedWasClean: boolean = await isClean(packageResolved);
  console.log("Derleniyor (xcodegen + xcodebuild)…");
  await runCommand("xcodegen", ["generate"], repoRoot, {});
  await runCommand(
    "xcodebuild",
    ["-project", app.project, "-scheme", app.scheme, "-configuration", "Debug", "-derivedDataPath", app.derivedDataPath, "-destination", `id=${udid}`, "build", "-quiet"],
    repoRoot,
    {},
  );
  if (resolvedWasClean && !(await isClean(packageResolved))) {
    await runCommand("git", ["checkout", "--", packageResolved], repoRoot, {});
  }
  return join(repoRoot, app.derivedDataPath, app.productPath);
}

/** Veri setini geçici bir klasöre yazar ve kimlikleri döndürür. */
async function seed(set: SeedSet, directory: string, timeZone: string): Promise<SeedManifest> {
  console.log(`Örnek veri yazılıyor (seeder: ${set})…`);
  await runCommand("swift", ["run", "--package-path", seederPackage, "AppStoreSeeder", set, directory], repoRoot, { TZ: timeZone });
  return JSON.parse(await readFile(join(directory, "seed-manifest.json"), "utf8")) as SeedManifest;
}

/** Ham çekimin ölçüsünü denetler (iPhone Duo kapalıysa dış ekran gelir: aygıtı Simülatör'de açıp yeniden çalıştır). */
async function checkCapture(file: string, simulator: DeviceTarget["simulator"]): Promise<void> {
  const meta: Metadata = await sharp(file).metadata();
  if (meta.width !== simulator.screenWidth || meta.height !== simulator.screenHeight) {
    throw new CaptureError(
      `${file}: ${meta.width}×${meta.height}, beklenen ${simulator.screenWidth}×${simulator.screenHeight} (aygıt türü: ${simulator.deviceType}; katlanabilir aygıt kapalıysa Simülatör'de aç)`,
    );
  }
}

/** Ekran neredeyse tek renk mi (açılış ekranı ya da henüz çizilmemiş görünüm): kanalların ortalama sapması çok düşük. */
async function isBlank(file: string): Promise<boolean> {
  const stats: Stats = await sharp(file).stats();
  const spread: number = stats.channels.slice(0, 3).reduce((sum: number, channel: ChannelStats) => sum + channel.stdev, 0) / 3;
  return spread < blankStdev;
}

/**
 * Sahneyi açar ve çeker. Uygulama çekimden önce kapanmışsa (çökme) hata verir; ekran boşsa (henüz çizilmedi) aynı
 * bekleme süresiyle yeniden çeker, `captureAttempts` denemeden sonra hata verir.
 */
async function captureScene(
  device: Simulator,
  target: DeviceTarget,
  scene: RawScene,
  args: readonly string[],
  timeZone: string,
  file: string,
): Promise<void> {
  await device.launch(app.bundleId, args, timeZone, scene.settleMs);
  for (let attempt: number = 1; attempt <= captureAttempts; attempt += 1) {
    if (!(await device.isRunning(app.bundleId))) {
      throw new CaptureError(
        `${scene.id}: uygulama çekimden önce kapandı (büyük olasılıkla çöktü; argümanlar: ${args.join(" ")}). Çökme raporu: ~/Library/Logs/DiagnosticReports/Gistsmith-*.ips`,
      );
    }
    await device.screenshot(file);
    await checkCapture(file, target.simulator);
    if (!(await isBlank(file))) {
      return;
    }
    console.warn(`${scene.id}: ekran boş (deneme ${attempt}/${captureAttempts}); ${scene.settleMs} ms sonra yeniden çekilecek`);
    await sleep(scene.settleMs);
  }
  throw new CaptureError(`${scene.id}: ${captureAttempts} denemede ekran boş kaldı (${file})`);
}

/** Sahnelerin veri setleri, ilk geçtikleri sırayla. Saf fonksiyondur. */
function seedSets(list: readonly RawScene[]): readonly SeedSet[] {
  return [...new Set<SeedSet>(list.map((scene: RawScene) => scene.seed))];
}

/**
 * Derler; her veri seti için Simülatörü temizleyip o veriyle hazırlar ve setin sahnelerini çeker. Çekimlerin yollarını
 * sahne kimliğiyle döndürür. Aygıt her setten sonra kapanır.
 */
async function capture(list: readonly RawScene[], directory: string, target: DeviceTarget): Promise<ReadonlyMap<string, string>> {
  const simulator: DeviceTarget["simulator"] = target.simulator;
  const timeZone: string = morningTimeZone(new Date().getUTCHours());
  const device: Simulator = await Simulator.ensure(simulator.name, simulator.deviceType, simulator.minRuntimeVersion, repoRoot);
  const appPath: string = await buildApp(device.udid);
  const work: string = await mkdtemp(join(tmpdir(), "appstore-seed-"));
  const captures: Map<string, string> = new Map<string, string>();
  try {
    await mkdir(directory, { recursive: true });
    for (const set of seedSets(list)) {
      const seedDirectory: string = join(work, set);
      const manifest: SeedManifest = await seed(set, seedDirectory, timeZone);
      console.log(`Simülatör hazırlanıyor: ${simulator.name} (${device.udid}), veri: ${set}`);
      await device.resetAndBoot(simulator.languages, simulator.locale);
      try {
        await device.prepareAppearance(["--time", statusBarClock(new Date(), timeZone), ...statusBarOverride]);
        await device.install(appPath);
        await device.copySeed(app.bundleId, app.dataFolder, seedDirectory, ["Sessions", "AskHistory"]);
        // Isınma: yeni açılmış aygıtta ilk açılış yavaştır (SpringBoard hazırlanıyor); ilk sahne ana ekranı çekmesin.
        await device.launch(app.bundleId, app.commonLaunchArgs, timeZone, warmUpMs);
        for (const scene of list.filter((candidate: RawScene) => candidate.seed === set)) {
          console.log(`Çekiliyor: ${scene.id}`);
          const file: string = join(directory, `${scene.id}.png`);
          await captureScene(device, target, scene, launchArguments(app.commonLaunchArgs, scene, manifest), timeZone, file);
          captures.set(scene.id, file);
        }
      } finally {
        await device.shutdown();
      }
    }
    return captures;
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

/** Ham çekimlerden App Store görsellerini, önizlemeleri ve paftayı üretir. */
async function compose(list: readonly Scene[], captures: ReadonlyMap<string, string>, chrome: string, target: DeviceTarget): Promise<void> {
  const outputSizes: readonly OutputSize[] = target.outputSizes;
  const previewFolder: string = target.previewFolder;
  const renderer: ChromeRenderer = await ChromeRenderer.launch(chrome);
  const work: string = await mkdtemp(join(tmpdir(), "appstore-compose-"));
  try {
    const previews: Buffer[] = [];
    // Çıktı klasörleri bu çalıştırmanın sahneleriyle baştan yazılır: önceki çalıştırmanın eskimiş görselleri kalmaz.
    for (const folder of [previewFolder, ...outputSizes.map((size: OutputSize) => size.id)]) {
      await rm(join(outputRoot, folder), { recursive: true, force: true });
      await mkdir(join(outputRoot, folder), { recursive: true });
    }
    for (const scene of list) {
      const screenshotPath: string | undefined = captures.get(scene.id);
      if (screenshotPath === undefined) {
        throw new CaptureError(`${scene.id}: ham çekim yok (${join(outputRoot, target.rawFolder, `${scene.id}.png`)}); önce tam çalıştır`);
      }
      const order: string = String(scenes.indexOf(scene) + 1).padStart(2, "0");
      for (const size of outputSizes) {
        const htmlPath: string = join(work, `${scene.id}-${size.id}.html`);
        await writeFile(htmlPath, sceneHtml(composeInput(scene, screenshotPath, size, target)), "utf8");
        const png: Buffer = await flattenToSrgbPng(await renderer.render(htmlPath, size.width, size.height, 1), size.width, size.height);
        const file: string = join(outputRoot, size.id, `${order}-${scene.id}.png`);
        await writeFile(file, png);
        console.log(file);
        if (size === outputSizes[0]) {
          const preview: Buffer = await previewJpeg(png, previewWidth);
          await writeFile(join(outputRoot, previewFolder, `${order}-${scene.id}.jpg`), preview);
          previews.push(png);
        }
      }
    }
    const sheet: string = join(outputRoot, previewFolder, "overview.jpg");
    await writeFile(sheet, await contactSheet(previews, 330, 24));
    console.log(sheet);
  } finally {
    await renderer.close();
    await rm(work, { recursive: true, force: true });
  }
}

/** Sahnenin şablon girdisi. Saf fonksiyondur. */
function composeInput(scene: Scene, screenshotPath: string, size: OutputSize, target: DeviceTarget): Parameters<typeof sceneHtml>[0] {
  return {
    headline: scene.headline,
    subhead: scene.subhead,
    screenshotPath,
    screenWidth: target.simulator.screenWidth,
    screenHeight: target.simulator.screenHeight,
    cameraCutout: target.cameraCutout,
    palette: palettes[scene.palette],
    clouds: scene.clouds,
    fontPath,
    size,
  };
}

/** Son tam çalıştırmanın ham çekimleri (raw/ ya da raw-duo/); eksik olan `compose` içinde hata verir. Saf fonksiyondur. */
function existingCaptures(list: readonly Scene[], target: DeviceTarget): ReadonlyMap<string, string> {
  return new Map<string, string>(list.map((scene: Scene) => [scene.id, join(outputRoot, target.rawFolder, `${scene.id}.png`)]));
}

async function main(): Promise<void> {
  const problems: readonly string[] = configProblems();
  if (problems.length > 0) {
    throw new ConfigError(`config.ts geçersiz:\n${problems.join("\n")}`);
  }
  const job: Job = parseJob(process.argv.slice(2));
  switch (job.kind) {
    case "full": {
      const captures: ReadonlyMap<string, string> = await capture(job.captures, join(outputRoot, job.target.rawFolder), job.target);
      if (job.scenes.length > 0) {
        await compose(job.scenes, captures, job.chrome, job.target);
      }
      break;
    }
    case "compose-only":
      await compose(job.scenes, existingCaptures(job.scenes, job.target), job.chrome, job.target);
      break;
    case "raw-only": {
      const directory: string = join(outputRoot, job.target.rawOnlyFolder);
      const captures: ReadonlyMap<string, string> = await capture(job.scenes, join(directory, "capture"), job.target);
      for (const scene of job.scenes) {
        const file: string | undefined = captures.get(scene.id);
        if (file === undefined) {
          throw new CaptureError(`${scene.id}: çekim yok`);
        }
        const output: string = join(directory, `${scene.id}.png`);
        await writeFile(output, await flattenToSrgbPng(await readFile(file), job.target.simulator.screenWidth, job.target.simulator.screenHeight));
        console.log(output);
      }
      await rm(join(directory, "capture"), { recursive: true, force: true });
      break;
    }
  }
}

await main();
