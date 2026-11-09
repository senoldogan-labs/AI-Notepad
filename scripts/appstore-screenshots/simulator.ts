// iOS Simülatör adaptörü (`xcrun simctl`): App Store çekimleri için ayrılmış aygıtı bulur ya da oluşturur, temizler,
// açar, uygulamayı kurar, örnek veriyi kopyalar, sahneyi açar ve ekranı çeker. Yalnız bu adla oluşturulan aygıta dokunur;
// kullanıcının diğer Simülatörlerine ve Mac uygulamasına dokunmaz.
import { cp, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { runCommand } from "./process.ts";

/** Simülatörle ilgili beklenmeyen durum (aygıt ya da çalışma zamanı bulunamadı, beklenmeyen yanıt). */
export class SimulatorError extends Error {
  override readonly name: string = "SimulatorError";
}

/** `simctl list -j` yanıtının kullanılan kısmı. */
interface SimctlDevice {
  readonly udid: string;
  readonly name: string;
  readonly state: string;
  readonly deviceTypeIdentifier: string;
}

interface SimctlRuntime {
  readonly identifier: string;
  readonly version: string;
  readonly buildversion: string;
  readonly platform: string;
  readonly isAvailable: boolean;
  readonly supportedDeviceTypes: readonly SimctlDeviceType[];
}

interface SimctlDeviceType {
  readonly identifier: string;
}

interface SimctlDeviceList {
  readonly devices: Readonly<Record<string, readonly SimctlDevice[]>>;
}

interface SimctlRuntimeList {
  readonly runtimes: readonly SimctlRuntime[];
}

/** Sürüm dizgelerini ("26.5", "26.10.1") sayısal karşılaştırır. Saf fonksiyondur. */
export function compareVersions(a: string, b: string): number {
  const left: readonly number[] = a.split(".").map((part: string) => Number(part));
  const right: readonly number[] = b.split(".").map((part: string) => Number(part));
  for (let index: number = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference: number = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) {
      return difference;
    }
  }
  return 0;
}

/**
 * Aygıt türünü listeleyen (`supportedDeviceTypes`) ve `minRuntimeVersion`'dan eski olmayan, kullanılabilir en yeni iOS
 * çalışma zamanı; yoksa kurulu iOS çalışma zamanlarını sayan hata. Sürüm yetmez: bir çalışma zamanı derlemesi aygıt
 * türünü listelemiyorsa `simctl create` yalnız "Incompatible device" der (ör. iOS 27.2 24B8117 iPhone Duo'yu listelemez).
 * Saf fonksiyondur.
 */
export function newestRuntimeFor(runtimes: readonly SimctlRuntime[], deviceType: string, minRuntimeVersion: string): SimctlRuntime {
  const ios: readonly SimctlRuntime[] = runtimes.filter((runtime: SimctlRuntime) => runtime.platform === "iOS" && runtime.isAvailable);
  const fitting: readonly SimctlRuntime[] = ios.filter(
    (runtime: SimctlRuntime) =>
      compareVersions(runtime.version, minRuntimeVersion) >= 0 &&
      runtime.supportedDeviceTypes.some((type: SimctlDeviceType) => type.identifier === deviceType),
  );
  const newest: SimctlRuntime | undefined = [...fitting].sort((a: SimctlRuntime, b: SimctlRuntime) => compareVersions(b.version, a.version))[0];
  if (newest === undefined) {
    const installed: string = ios.map((runtime: SimctlRuntime) => `${runtime.version} (${runtime.buildversion})`).join(", ");
    throw new SimulatorError(
      `${deviceType} aygıtını listeleyen, en az iOS ${minRuntimeVersion} bir Simülatör çalışma zamanı yok (kurulu iOS: ${installed || "yok"}). Xcode › Settings › Components'ten bu aygıt türünü destekleyen iOS çalışma zamanını kur.`,
    );
  }
  return newest;
}

/** `launchctl list` çıktısında uygulamanın PID'li satırı var mı (çalışıyor mu). Saf fonksiyondur. */
export function appIsRunning(listing: string, bundleId: string): boolean {
  return listing.split("\n").some((line: string) => {
    const [pid, , label] = line.split("\t");
    return label !== undefined && label.startsWith(`UIKitApplication:${bundleId}[`) && pid !== undefined && /^\d+$/.test(pid);
  });
}

/** `simctl`'i çağıran adaptör; tek bir aygıta bağlıdır. */
export class Simulator {
  readonly udid: string;
  private readonly cwd: string;

  private constructor(udid: string, cwd: string) {
    this.udid = udid;
    this.cwd = cwd;
  }

  /**
   * Bu adlı aygıtı bulur; yoksa aygıt türünü destekleyen en yeni iOS çalışma zamanıyla (`newestRuntimeFor`) oluşturur.
   * Aynı adla birden çok aygıt varsa ya da uygun çalışma zamanı yoksa hata.
   */
  static async ensure(name: string, deviceType: string, minRuntimeVersion: string, cwd: string): Promise<Simulator> {
    const listed: SimctlDeviceList = JSON.parse((await runCommand("xcrun", ["simctl", "list", "devices", "-j"], cwd, {})).stdout) as SimctlDeviceList;
    const matches: readonly SimctlDevice[] = Object.values(listed.devices).flat().filter((device: SimctlDevice) => device.name === name);
    if (matches.length > 1) {
      throw new SimulatorError(`"${name}" adlı ${matches.length} aygıt var (${matches.map((d: SimctlDevice) => d.udid).join(", ")}); fazlasını sil: xcrun simctl delete <udid>`);
    }
    const existing: SimctlDevice | undefined = matches[0];
    if (existing !== undefined) {
      if (existing.deviceTypeIdentifier !== deviceType) {
        throw new SimulatorError(`"${name}" aygıtının türü ${existing.deviceTypeIdentifier}, beklenen ${deviceType}; aygıtı sil: xcrun simctl delete ${existing.udid}`);
      }
      return new Simulator(existing.udid, cwd);
    }
    const runtimes: SimctlRuntimeList = JSON.parse((await runCommand("xcrun", ["simctl", "list", "runtimes", "-j"], cwd, {})).stdout) as SimctlRuntimeList;
    const runtime: SimctlRuntime = newestRuntimeFor(runtimes.runtimes, deviceType, minRuntimeVersion);
    console.log(`Simülatör oluşturuluyor: ${name} (${deviceType}, iOS ${runtime.version})`);
    const udid: string = (await runCommand("xcrun", ["simctl", "create", name, deviceType, runtime.identifier], cwd, {})).stdout.trim();
    return new Simulator(udid, cwd);
  }

  private async simctl(args: readonly string[], env: Readonly<Record<string, string>>): Promise<string> {
    return (await runCommand("xcrun", ["simctl", ...args], this.cwd, env)).stdout;
  }

  private async state(): Promise<string> {
    const listed: SimctlDeviceList = JSON.parse(await this.simctl(["list", "devices", "-j"], {})) as SimctlDeviceList;
    const device: SimctlDevice | undefined = Object.values(listed.devices).flat().find((d: SimctlDevice) => d.udid === this.udid);
    if (device === undefined) {
      throw new SimulatorError(`Simülatör kayboldu: ${this.udid}`);
    }
    return device.state;
  }

  /**
   * Aygıtı kapatır, siler (önceki çalıştırmanın verisi ve izinleri kalmaz), sistem dilini ve bölgesini ayarlayıp yeniden
   * açar: durum çubuğu ve sistem metinleri Mac'in dilinden bağımsız olur ("9:41", İngilizce). Açılışın bitmesini bekler.
   */
  async resetAndBoot(languages: readonly string[], locale: string): Promise<void> {
    if ((await this.state()) !== "Shutdown") {
      await this.simctl(["shutdown", this.udid], {});
    }
    await this.simctl(["erase", this.udid], {});
    await this.boot();
    await this.simctl(["spawn", this.udid, "defaults", "write", "-g", "AppleLanguages", "-array", ...languages], {});
    await this.simctl(["spawn", this.udid, "defaults", "write", "-g", "AppleLocale", "-string", locale], {});
    await this.simctl(["shutdown", this.udid], {});
    await this.boot();
  }

  private async boot(): Promise<void> {
    await this.simctl(["boot", this.udid], {});
    await this.simctl(["bootstatus", this.udid, "-b"], {});
  }

  /** Açık görünüm ve sabit durum çubuğu. */
  async prepareAppearance(statusBar: readonly string[]): Promise<void> {
    await this.simctl(["ui", this.udid, "appearance", "light"], {});
    await this.simctl(["status_bar", this.udid, "override", ...statusBar], {});
  }

  async install(appPath: string): Promise<void> {
    await this.simctl(["install", this.udid, appPath], {});
  }

  /** Uygulamanın veri kabı (kurulumdan sonra vardır). */
  async dataContainer(bundleId: string): Promise<string> {
    return (await this.simctl(["get_app_container", this.udid, bundleId, "data"], {})).trim();
  }

  /** Örnek veri klasörünün içindekileri (Sessions, AskHistory) uygulamanın veri klasörüne kopyalar; öncekini siler. */
  async copySeed(bundleId: string, dataFolder: string, seedDirectory: string, folders: readonly string[]): Promise<void> {
    const target: string = join(await this.dataContainer(bundleId), dataFolder);
    await mkdir(target, { recursive: true });
    for (const folder of folders) {
      await rm(join(target, folder), { recursive: true, force: true });
      await cp(join(seedDirectory, folder), join(target, folder), { recursive: true });
    }
  }

  /**
   * Uygulamayı (açıksa kapatıp) argümanlarla açar; `timeZone` uygulamanın saat dilimidir (`SIMCTL_CHILD_TZ`). `settleMs`
   * sonra döner.
   */
  async launch(bundleId: string, args: readonly string[], timeZone: string, settleMs: number): Promise<void> {
    await this.simctl(["launch", "--terminate-running-process", this.udid, bundleId, ...args], { SIMCTL_CHILD_TZ: timeZone });
    await sleep(settleMs);
  }

  /** Uygulama çalışıyor mu (launchd'de PID'i var mı); çöken ya da kapanan uygulamada false. */
  async isRunning(bundleId: string): Promise<boolean> {
    const listing: string = await this.simctl(["spawn", this.udid, "launchctl", "list"], {});
    return appIsRunning(listing, bundleId);
  }

  /** Ekranı PNG olarak çeker (köşe maskesi yok: dikdörtgen tam çerçeve). */
  async screenshot(file: string): Promise<void> {
    await this.simctl(["io", this.udid, "screenshot", "--type=png", "--mask=ignored", file], {});
  }

  /** Durum çubuğu ayarını kaldırır ve aygıtı kapatır. */
  async shutdown(): Promise<void> {
    await this.simctl(["status_bar", this.udid, "clear"], {});
    await this.simctl(["shutdown", this.udid], {});
  }
}
