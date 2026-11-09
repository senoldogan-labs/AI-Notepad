// App Store ekran görüntülerinin tek düzenlenebilir ayar dosyası: sahneler (başlatma argümanları ve metinler), boyutlar,
// Simülatör ve uygulama. Metinler İngilizcedir (App Store sayfası); başlık en çok 30, alt başlık en çok 60 karakter
// (make.ts başlamadan denetler). iPhone yalnızca yanındaki konuşmayı mikrofonla kaydeder: metinler Zoom ya da telefon
// görüşmesi kaydettiğini söylemez.

/** Sitedeki film gradyanlarının renk takımları (web/src/styles/global.css, `.film--*`; adlar uygulamanın FilmPalette adları). */
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

/**
 * Çekimin örnek veri seti (seeder/ `SeedPersona`): ekip toplantıları, dersler ya da görüşmeler. Her set Simülatörü
 * temizleyip kendi verisiyle açar.
 */
export type SeedSet = "team" | "lectures" | "interviews";

/** Uygulamanın bir ekranı: nasıl açılacağı. `--raw-only` yalnız bunu kullanır (başlıksız, çerçevesiz çekim). */
export interface RawScene {
  /** Dosya adı ve `--scene` / `--raw-only` değeri. */
  readonly id: string;
  /** Uygulamaya yüklenen örnek veri. */
  readonly seed: SeedSet;
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

/** Çerçevede ekranın üstündeki kamera kesiği: Dynamic Island ya da hiçbiri (iPhone Duo'nun iç ekranı). */
export type CameraCutout = "island" | "none";

/** Çekimi yapan Simülatör aygıtı: bu adla yoksa oluşturulur, her çalıştırmada silinip temiz açılır. */
export interface SimulatorConfig {
  readonly name: string;
  readonly deviceType: string;
  /** Aygıt türünün istediği en eski iOS çalışma zamanı (ör. iPhone Duo için 27.1). */
  readonly minRuntimeVersion: string;
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

/**
 * Sitenin varsayılan "Warm Ember" aileleri (web/src/styles/global.css `.film--*`; sunset = ember, coral = clay, ocean =
 * dusk, mint = sage, rose = rosewood, violet = sand). Uygulama da Kor paletiyle çekilir (`-appearance.themeFamily ember`).
 */
export const palettes: Readonly<Record<PaletteName, Palette>> = {
  sunset: { base: "#bd976f", c0: "#d2b48e", c1: "#f4e8da", c2: "#b07872", c3: "#a5664b" },
  coral: { base: "#c98a64", c0: "#ddb08e", c1: "#f0dcc4", c2: "#bd976f", c3: "#a86a4c" },
  ocean: { base: "#a88a97", c0: "#c4abb4", c1: "#e9d6d6", c2: "#bd976f", c3: "#836877" },
  mint: { base: "#a9ac92", c0: "#c3c4ad", c1: "#e4e2cf", c2: "#d2b48e", c3: "#878c72" },
  rose: { base: "#b07872", c0: "#c99a91", c1: "#e9c9c1", c2: "#a88a97", c3: "#935a57" },
  violet: { base: "#d2b48e", c0: "#e0c9a8", c1: "#f3e9da", c2: "#bd976f", c3: "#b8946a" },
};

/**
 * Toplantı kimliği: veri setinin notu açılan toplantısı ("Product weekly", "Cognitive Psychology · Memory" ya da
 * "User interview · Sara"); klasör adı çalıştırma anında bilinir (bkz. make.ts).
 */
export const meetingPlaceholder: string = "{meeting}";

/** Sor sohbetinin kimliği: veri setinin üç kaynaklı örnek sohbeti (bkz. make.ts). */
export const askConversationPlaceholder: string = "{askConversation}";

/** Görsellerin sırası App Store'daki sıradır: ilk ikisi arama sonuçlarında görünür. */
export const scenes: readonly Scene[] = [
  {
    id: "home",
    seed: "team",
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
    seed: "team",
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
    seed: "team",
    headline: "Notes that write themselves",
    subhead: "Summary, decisions and tasks, ready when it ends.",
    launchArgs: ["--toplanti", meetingPlaceholder],
    settleMs: 5000,
    palette: "ocean",
    clouds: "left",
  },
  {
    id: "ask",
    seed: "team",
    headline: "Ask your meetings",
    subhead: "Plain-language answers that cite the meeting.",
    launchArgs: ["--sohbet", askConversationPlaceholder],
    settleMs: 4000,
    palette: "violet",
    clouds: "right",
  },
  {
    id: "tasks",
    seed: "team",
    headline: "Never drop a follow-up",
    subhead: "Your tasks from every meeting, in one list.",
    launchArgs: ["--sekme", "gorevler"],
    settleMs: 4000,
    palette: "mint",
    clouds: "left",
  },
  {
    id: "templates",
    seed: "team",
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
    seed: "team",
    launchArgs: ["--paywall"],
    settleMs: 7000,
  },
  // Görsel kontrol (App Store setine girmez): ana ekran, Ayarlar › Tanıma ve konuşmacılar (sesinden tanıma açık),
  // Ayarlar › Hesap ve toplantı sayfasının başlığı; açık ve koyu temada.
  ...(["light", "dark"] as const).flatMap((theme: "light" | "dark"): readonly RawScene[] => {
    const themeArgs: readonly string[] = ["-appearance.theme", theme];
    return [
      { id: `qa-home-${theme}`, seed: "team", launchArgs: ["--abone", "--ornek-takvim", ...themeArgs], settleMs: 5000 },
      { id: `qa-speakers-${theme}`, seed: "team", launchArgs: ["--sekme", "ayarlar", "--ayar", "konusmacilar", "-voiceRecognition", "YES", ...themeArgs], settleMs: 5000 },
      { id: `qa-account-${theme}`, seed: "team", launchArgs: ["--abone", "--ekran", "hesap", ...themeArgs], settleMs: 5000 },
      { id: `qa-meeting-${theme}`, seed: "team", launchArgs: ["--toplanti", meetingPlaceholder, ...themeArgs], settleMs: 5000 },
    ];
  }),
];

/**
 * Özel ürün sayfalarının çekimleri (`customPages`; ana sete girmez). Tam çalıştırma bunları da çeker; her biri kendi
 * veri setiyle.
 */
export const pageScenes: readonly RawScene[] = [
  // Ana ekran takvimsiz: kayıt düğmesi öne çıkar ("One tap to start").
  { id: "record", seed: "team", launchArgs: ["--abone"], settleMs: 5000 },
  { id: "lecture-home", seed: "lectures", launchArgs: ["--abone"], settleMs: 5000 },
  { id: "lecture-note", seed: "lectures", launchArgs: ["--toplanti", meetingPlaceholder], settleMs: 5000 },
  { id: "lecture-ask", seed: "lectures", launchArgs: ["--sohbet", askConversationPlaceholder], settleMs: 4000 },
  { id: "lecture-library", seed: "lectures", launchArgs: ["--ekran", "kitaplik"], settleMs: 4000 },
  { id: "interview-note", seed: "interviews", launchArgs: ["--toplanti", meetingPlaceholder], settleMs: 5000 },
  { id: "interview-ask", seed: "interviews", launchArgs: ["--sohbet", askConversationPlaceholder], settleMs: 4000 },
  { id: "interview-people", seed: "interviews", launchArgs: ["--ekran", "kisiler"], settleMs: 4000 },
  { id: "interview-library", seed: "interviews", launchArgs: ["--ekran", "kitaplik"], settleMs: 4000 },
];

/** 6.9" zorunlu; 6.5" ve 6.3" aynı çekimden piksel piksel yeniden düzenlenir (ölçekleme değil). */
export const outputSizes: readonly OutputSize[] = [
  { id: "6.9", width: 1320, height: 2868 },
  { id: "6.5", width: 1284, height: 2778 },
  { id: "6.3", width: 1206, height: 2622 },
];

/** Özel ürün sayfalarının boyutları. */
export const customPageSizes: readonly OutputSize[] = [
  { id: "6.9", width: 1320, height: 2868 },
  { id: "6.3", width: 1206, height: 2622 },
];

/** Ürün sayfası başlığının ve arama görselinin metni (satır satır). */
export interface BannerCopy {
  readonly headline: readonly string[];
  readonly subhead: readonly string[];
}

/** Bir başlık görseli: metin, üç çekim (ortadaki öne çıkar) ve zemin. */
export interface Banner {
  readonly copy: BannerCopy;
  readonly shots: readonly [string, string, string];
  readonly palette: PaletteName;
  readonly clouds: CloudSide;
}

/** Ana ürün sayfasının başlığı (21:9): ortada ana ekran. */
export const productHeader: Banner = {
  copy: { headline: ["Your meetings,", "already written up."], subhead: ["When the meeting ends,", "your note is ready."] },
  shots: ["note", "home", "tasks"],
  palette: "violet",
  clouds: "left",
};

/** Arama sonucu görseli (3:2). */
export const searchBanner: Banner = {
  copy: { headline: ["Put your iPhone on the table."], subhead: ["When the meeting ends, your note is ready."] },
  shots: ["live", "note", "tasks"],
  palette: "ocean",
  clouds: "right",
};

/** In-App Event görsellerinin (metinsiz; adı ve açıklamayı App Store bindirir) çekimleri ve zemini. */
export const eventArt: Omit<Banner, "copy"> = {
  shots: ["live", "note", "home"],
  palette: "sunset",
  clouds: "right",
};

/** Özel ürün sayfasının bir ekran görüntüsü: ham çekim (`scenes` ya da `pageScenes` kimliği) ve metin. */
export interface PageShot {
  readonly raw: string;
  /** En çok 30 karakter. */
  readonly headline: string;
  /** En çok 60 karakter. */
  readonly subhead: string;
  readonly palette: PaletteName;
  readonly clouds: CloudSide;
}

/** Özel ürün sayfası (docs/appstore/custom-product-pages.md): ekran görüntüleri sırasıyla ve varsa kendi başlığı. */
export interface CustomPage {
  /** App Store Connect'teki referans adı ve çıktı klasörü. */
  readonly id: string;
  readonly shots: readonly PageShot[];
  /** Kendi ürün sayfası başlığı; null ana başlığı kullanır. */
  readonly header: Banner | null;
}

export const customPages: readonly CustomPage[] = [
  {
    id: "cpp-students-lectures",
    shots: [
      { raw: "live", headline: "Never miss what was said", subhead: "Live transcript of the lecture, speaker by speaker.", palette: "sunset", clouds: "right" },
      { raw: "lecture-note", headline: "Lecture notes, done", subhead: "Key points and to-dos, ready when class ends.", palette: "ocean", clouds: "left" },
      { raw: "lecture-ask", headline: "Revise by asking", subhead: "“What did the lecturer say about the exam?”", palette: "violet", clouds: "right" },
      { raw: "lecture-library", headline: "Every class, searchable", subhead: "Find any topic by word, course or date.", palette: "mint", clouds: "left" },
      { raw: "lecture-home", headline: "One tap to start", subhead: "Put your iPhone on the desk and press record.", palette: "coral", clouds: "right" },
    ],
    header: {
      copy: { headline: ["Lectures,", "already written up."], subhead: ["When class ends,", "your notes are ready."] },
      shots: ["lecture-note", "lecture-home", "lecture-ask"],
      palette: "ocean",
      clouds: "left",
    },
  },
  {
    id: "cpp-interviews-research",
    shots: [
      { raw: "live", headline: "Every answer, word for word", subhead: "A live transcript, separated by speaker.", palette: "sunset", clouds: "right" },
      { raw: "interview-ask", headline: "Ask across interviews", subhead: "Plain-language answers that cite each interview.", palette: "violet", clouds: "left" },
      { raw: "interview-note", headline: "Key points, not just text", subhead: "Summary, glossary and follow-ups for each interview.", palette: "ocean", clouds: "right" },
      { raw: "interview-people", headline: "Know who said what", subhead: "Name speakers once; see their meetings and talk time.", palette: "rose", clouds: "left" },
      { raw: "interview-library", headline: "Bring your recordings", subhead: "Import audio or video from Files or Photos.", palette: "mint", clouds: "right" },
    ],
    header: {
      copy: { headline: ["Interviews,", "word for word."], subhead: ["A transcript by speaker,", "a note when it ends."] },
      shots: ["interview-ask", "interview-note", "interview-library"],
      palette: "rose",
      clouds: "left",
    },
  },
  {
    id: "cpp-team-meetings",
    shots: [
      { raw: "tasks", headline: "Never drop a follow-up", subhead: "Your tasks from every meeting, in one list.", palette: "mint", clouds: "left" },
      { raw: "note", headline: "Decisions, written down", subhead: "Summary, decisions and tasks, ready when it ends.", palette: "ocean", clouds: "right" },
      { raw: "home", headline: "Walk in prepared", subhead: "A briefing on past meetings with the same people.", palette: "coral", clouds: "left" },
      { raw: "ask", headline: "Ask your meetings", subhead: "Plain-language answers that cite the meeting.", palette: "violet", clouds: "right" },
      { raw: "record", headline: "One tap to start", subhead: "Put your iPhone on the table and press record.", palette: "sunset", clouds: "left" },
    ],
    header: null,
  },
];

const headlineLimit: number = 30;
const subheadLimit: number = 60;

/** Bir metnin sınır sorunları (boşsa geçerli). Saf fonksiyondur. */
function copyProblems(id: string, headline: string, subhead: string | null): readonly string[] {
  return [
    ...(headline.length > headlineLimit ? [`${id}: başlık ${headline.length} karakter (en çok ${headlineLimit}): "${headline}"`] : []),
    ...(subhead !== null && subhead.length > subheadLimit ? [`${id}: alt başlık ${subhead.length} karakter (en çok ${subheadLimit}): "${subhead}"`] : []),
  ];
}

/**
 * Ayar dosyasının sorunları (boşsa geçerli): yinelenen sahne kimlikleri, uzun metinler, olmayan çekime başvuran sayfa
 * ve başlık görselleri. Saf fonksiyondur.
 */
export function configProblems(): readonly string[] {
  const all: readonly RawScene[] = [...scenes, ...pageScenes, ...rawScenes];
  const ids: readonly string[] = all.map((scene: RawScene) => scene.id);
  const duplicates: readonly string[] = ids.filter((id: string, index: number) => ids.indexOf(id) !== index);
  const captured: ReadonlySet<string> = new Set<string>([...scenes, ...pageScenes].map((scene: RawScene) => scene.id));
  const banners: readonly Banner[] = [productHeader, searchBanner, ...customPages.flatMap((page: CustomPage) => (page.header === null ? [] : [page.header]))];
  const referenced: readonly string[] = [
    ...banners.flatMap((banner: Banner) => banner.shots),
    ...eventArt.shots,
    ...customPages.flatMap((page: CustomPage) => page.shots.map((shot: PageShot) => shot.raw)),
  ];
  return [
    ...duplicates.map((id: string) => `Sahne kimliği iki kez geçiyor: ${id}`),
    ...scenes.flatMap((scene: Scene) => copyProblems(scene.id, scene.headline, scene.subhead)),
    ...customPages.flatMap((page: CustomPage) =>
      page.shots.flatMap((shot: PageShot, index: number) => copyProblems(`${page.id} #${index + 1}`, shot.headline, shot.subhead)),
    ),
    ...referenced.filter((id: string) => !captured.has(id)).map((id: string) => `Bilinmeyen çekim (scenes ya da pageScenes'te yok): ${id}`),
  ];
}

export const simulator: SimulatorConfig = {
  name: "Gistsmith App Store 6.9",
  deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
  minRuntimeVersion: "26.0",
  languages: ["en"],
  locale: "en_US",
  screenWidth: 1320,
  screenHeight: 2868,
};

/** Bir çekim hattı: Simülatör aygıtı, çıktı boyutları ve çerçevenin kamera kesiği (`make.ts --device`). */
export interface DeviceTarget {
  readonly simulator: SimulatorConfig;
  readonly outputSizes: readonly OutputSize[];
  readonly cameraCutout: CameraCutout;
  /** Ham çekimlerin, `--raw-only` çıktısının ve önizlemelerin klasörleri (.build/appstore-screenshots altında). */
  readonly rawFolder: string;
  readonly rawOnlyFolder: string;
  readonly previewFolder: string;
}

/**
 * iPhone Duo (katlanabilir, iOS 27.1+): App Store Connect iç ekran için 2007×2853 (yan: 2853×2007), dış ekran için
 * 1398×2034 ister; iOS 27.1 SDK'sıyla derlenen uygulamalarda Nisan 2027'den sonra zorunlu, yüklenince ürün sayfasında
 * "iPhone Duo için" işareti çıkar. Duo'ya özgü görsel iç ekrandır (iki sütunlu düzen); dış ekran normal iPhone'un tek
 * sütunlu arayüzüdür. Aygıt açık (unfolded) olmalı: Simülatör kapalı açılırsa çekim 1398×2034 gelir ve hat durur.
 */
export const duoSimulator: SimulatorConfig = {
  name: "Gistsmith App Store Duo",
  deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
  minRuntimeVersion: "27.1",
  languages: ["en"],
  locale: "en_US",
  screenWidth: 2007,
  screenHeight: 2853,
};

export const devices: Readonly<Record<"iphone" | "duo", DeviceTarget>> = {
  iphone: { simulator, outputSizes, cameraCutout: "island", rawFolder: "raw", rawOnlyFolder: "raw-only", previewFolder: "previews" },
  duo: {
    simulator: duoSimulator,
    outputSizes: [{ id: "duo", width: 2007, height: 2853 }],
    cameraCutout: "none",
    rawFolder: "raw-duo",
    rawOnlyFolder: "raw-only-duo",
    previewFolder: "previews-duo",
  },
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
    "-appearance.themeFamily",
    "ember",
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
