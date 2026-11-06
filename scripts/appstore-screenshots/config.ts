// App Store ekran görüntülerinin tek düzenlenebilir ayar dosyası: sahneler (başlatma argümanları ve metinler), boyutlar,
// Simülatör ve uygulama. Metinler İngilizcedir (App Store sayfası); başlık en çok 30, alt başlık en çok 60 karakter
// (make.ts başlamadan denetler). iPhone yalnızca yanındaki konuşmayı mikrofonla kaydeder: metinler Zoom ya da telefon
// görüşmesi kaydettiğini söylemez.

/** Sitedeki film gradyanlarının renk takımları (web/src/styles/global.css, `.film--*`). */
export type PaletteName = "sunset" | "coral" | "ocean" | "mint" | "rose" | "violet";

/** Bulutların gölgesinin olduğu taraf (sitedeki `.film--clouds-left` / `-right`). */
export type CloudSide = "left" | "right";

/** Bir film gradyanının beş rengi: zemin ve dört bulut. */
export interface Palette {
  readonly base: string;
  readonly c0: string;
  readonly c1: string;
  readonly c2: string;
  readonly c3: string;
}

/** Uygulamanın bir ekranı: nasıl açılacağı. `--raw-only` yalnız bunu kullanır (başlıksız, çerçevesiz çekim). */
export interface RawScene {
  /** Dosya adı ve `--scene` / `--raw-only` değeri. */
  readonly id: string;
  /** Uygulamanın başlatma argümanları (yalnız Debug derlemede tanınan görsel kontrol argümanları dahil). */
  readonly launchArgs: readonly string[];
  /** Açıldıktan sonra çekime dek bekleme (ms): veri okuma ve geçiş animasyonları biter. */
  readonly settleMs: number;
}

/** Bir App Store sahnesi: uygulamanın hangi ekranla açılacağı ve görselin metni. */
export interface Scene extends RawScene {
  /** Başlık (en çok 30 karakter). */
  readonly headline: string;
  /** Tek satırlık alt başlık (en çok 60 karakter); yoksa null. */
  readonly subhead: string | null;
  readonly palette: PaletteName;
  readonly clouds: CloudSide;
}

/** Çıktı boyutu (App Store Connect'in kabul ettiği piksel ölçüleri). */
export interface OutputSize {
  /** Klasör adı, ör. "6.9". */
  readonly id: string;
  readonly width: number;
  readonly height: number;
}

/** Çekimi yapan Simülatör aygıtı: bu adla yoksa oluşturulur, her çalıştırmada silinip temiz açılır. */
export interface SimulatorConfig {
  readonly name: string;
  readonly deviceType: string;
  /** Sistem dili ve bölgesi (durum çubuğu saati, sistem metinleri). */
  readonly languages: readonly string[];
  readonly locale: string;
  /** Çekimin piksel ölçüsü (aygıtın ekranı); farklı çıkarsa hat durur. */
  readonly screenWidth: number;
  readonly screenHeight: number;
}

/** Çekilecek uygulama. */
export interface AppConfig {
  readonly project: string;
  readonly scheme: string;
  readonly bundleId: string;
  readonly derivedDataPath: string;
  /** Derlenen .app'in derived data altındaki yolu. */
  readonly productPath: string;
  /** Uygulamanın veri klasörü, veri kabına göre (Sessions ve AskHistory buraya kopyalanır). */
  readonly dataFolder: string;
  /** Her sahnede verilen argümanlar: dil, onboarding atlama, ad ve görünüm. */
  readonly commonLaunchArgs: readonly string[];
}

export const palettes: Readonly<Record<PaletteName, Palette>> = {
  sunset: { base: "#f0ae92", c0: "#f7cdb8", c1: "#fff3e6", c2: "#c9a3e0", c3: "#e9896a" },
  coral: { base: "#f0c49b", c0: "#f7dcc0", c1: "#fff6e8", c2: "#f2a7b4", c3: "#e0a36f" },
  ocean: { base: "#a9bcee", c0: "#cbd6f6", c1: "#f4f1ff", c2: "#e9b9d6", c3: "#8ea3e6" },
  mint: { base: "#a9cdb8", c0: "#cce3d4", c1: "#f6f7ea", c2: "#e9d7a8", c3: "#7fb096" },
  rose: { base: "#eba7b5", c0: "#f6cbd4", c1: "#fff1ec", c2: "#b9c9f0", c3: "#de8aa3" },
  violet: { base: "#c7b3ec", c0: "#ded1f5", c1: "#fff4ee", c2: "#f4c0a8", c3: "#a98bdb" },
};

/** Toplantı kimliği: tohumlayıcının "Product weekly" klasör adı, çalıştırma anında bilinir (bkz. make.ts). */
export const productWeeklyPlaceholder: string = "{productWeekly}";

/** Sor sohbetinin kimliği: tohumlayıcının üç kaynaklı örnek sohbeti (bkz. make.ts). */
export const askConversationPlaceholder: string = "{askConversation}";

/** Görsellerin sırası App Store'daki sıradır: ilk ikisi arama sonuçlarında görünür. */
export const scenes: readonly Scene[] = [
  {
    id: "home",
    headline: "Your day at a glance",
    subhead: "Today's meetings and the tasks waiting for you.",
    // `--abone`: deneme satırı ("Free trial: …") görünmez.
    launchArgs: ["--abone", "--ornek-takvim"],
    settleMs: 5000,
    palette: "coral",
    clouds: "left",
  },
  {
    id: "live",
    headline: "Every word, as it’s spoken",
    subhead: "Live transcript and translation for in-person meetings.",
    launchArgs: ["--ornek-kayit"],
    // Katılımcılara söyle uyarısı 3 sn sonra kaybolur; yüklü makinede geçişi de bitsin.
    settleMs: 9000,
    palette: "sunset",
    clouds: "right",
  },
  {
    id: "note",
    headline: "Notes that write themselves",
    subhead: "Summary, decisions and tasks, ready when it ends.",
    launchArgs: ["--toplanti", productWeeklyPlaceholder],
    settleMs: 5000,
    palette: "ocean",
    clouds: "left",
  },
  {
    id: "ask",
    headline: "Ask your meetings",
    subhead: "Plain-language answers that cite the meeting.",
    launchArgs: ["--sohbet", askConversationPlaceholder],
    settleMs: 4000,
    palette: "violet",
    clouds: "right",
  },
  {
    id: "tasks",
    headline: "Never drop a follow-up",
    subhead: "Your tasks from every meeting, in one list.",
    launchArgs: ["--sekme", "gorevler"],
    settleMs: 4000,
    palette: "mint",
    clouds: "left",
  },
  {
    id: "templates",
    headline: "Notes shaped your way",
    subhead: "Templates for every kind of meeting.",
    launchArgs: ["--sablon-galerisi"],
    settleMs: 4000,
    palette: "rose",
    clouds: "right",
  },
];

/**
 * Yalnız ham çekim olarak istenen ekranlar (`--raw-only <kimlik>`; pazarlama setine girmez). App Store Connect her
 * abonelik için bir inceleme görseli ister: `paywall` uygulamanın abonelik ekranıdır (`--paywall`; paketler RevenueCat'ten,
 * fiyatlar App Store sandbox'ından okunur: ağ gerekir, Apple Hesabı gerekmez). Yukarıdaki sahneler de `--raw-only` ile
 * çekilebilir.
 */
export const rawScenes: readonly RawScene[] = [
  {
    id: "paywall",
    launchArgs: ["--paywall"],
    settleMs: 7000,
  },
  // Görsel kontrol (App Store setine girmez): ana ekran, Ayarlar › Tanıma ve konuşmacılar (sesinden tanıma açık),
  // Ayarlar › Hesap ve toplantı sayfasının başlığı; açık ve koyu temada.
  ...(["light", "dark"] as const).flatMap((theme: "light" | "dark"): readonly RawScene[] => {
    const themeArgs: readonly string[] = ["-appearance.theme", theme];
    return [
      { id: `qa-home-${theme}`, launchArgs: ["--abone", "--ornek-takvim", ...themeArgs], settleMs: 5000 },
      { id: `qa-speakers-${theme}`, launchArgs: ["--sekme", "ayarlar", "--ayar", "konusmacilar", "-voiceRecognition", "YES", ...themeArgs], settleMs: 5000 },
      { id: `qa-account-${theme}`, launchArgs: ["--abone", "--ekran", "hesap", ...themeArgs], settleMs: 5000 },
      { id: `qa-meeting-${theme}`, launchArgs: ["--toplanti", productWeeklyPlaceholder, ...themeArgs], settleMs: 5000 },
    ];
  }),
];

/** 6.9" zorunlu; 6.5" aynı çekimden ucuza üretilir. */
export const outputSizes: readonly OutputSize[] = [
  { id: "6.9", width: 1320, height: 2868 },
  { id: "6.5", width: 1284, height: 2778 },
];

export const simulator: SimulatorConfig = {
  name: "Gistsmith App Store 6.9",
  deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
  languages: ["en"],
  locale: "en_US",
  screenWidth: 1320,
  screenHeight: 2868,
};

export const app: AppConfig = {
  project: "AINotepad.xcodeproj",
  scheme: "AINotepadiOS",
  bundleId: "com.senoldogan.AINotepad.hosted",
  derivedDataPath: ".build/xcode-appstore",
  productPath: "Build/Products/Debug-iphonesimulator/Gistsmith.app",
  // Tanıtım hesabının (`--tanitim`, kimlik "tanitim") veri klasörü: Debug veri klasörü + Accounts/<accountDataKey("tanitim")>.
  dataFolder: "Library/Application Support/AINotepad Hosted Debug/Accounts/840e998c43c314a273d650cdfc0a3559",
  commonLaunchArgs: [
    // Tanıtım modu (yalnız Debug): sunucuya bağlanmadan sahte denemedeki hesapla açılır; giriş ve açıklama atlanır.
    "--tanitim",
    "-AppleLanguages",
    "(en)",
    "-AppleLocale",
    "en_US",
    "-onboardingCompleted",
    "YES",
    "-userName",
    "Alex Morgan",
    "-appearance.theme",
    "light",
    "-language.note",
    "en",
  ],
};

/** Simülatörün durum çubuğu: tam pil, tam çekim. Saati make.ts uygulamanın saat dilimine göre ekler. */
export const statusBarOverride: readonly string[] = [
  "--batteryState",
  "discharging",
  "--batteryLevel",
  "100",
  "--cellularMode",
  "active",
  "--cellularBars",
  "4",
  "--wifiMode",
  "active",
  "--wifiBars",
  "3",
  "--dataNetwork",
  "wifi",
  "--operatorName",
  "",
];
