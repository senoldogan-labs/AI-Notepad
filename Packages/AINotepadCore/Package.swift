// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AINotepadCore",
    // Arayüz metinleri Türkçe yazılır; çalışma anında uygulamanın String Catalog'undan (ana paket) çevrilir.
    defaultLocalization: "tr",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AINotepadCore", targets: ["AINotepadCore"]),
        .library(name: "AINotepadUI", targets: ["AINotepadUI"]),
        // iPhone klavye uzantısının mantığı: bağımlılıksız (uzantının bellek sınırı için WhisperKit ve AINotepadCore'a
        // bağlanmaz).
        .library(name: "KeyboardCore", targets: ["KeyboardCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // iPhone ↔ Apple Watch messages: the iPhone-side mapping from the recorder state lives here.
        .package(path: "../AINotepadWatchLink"),
    ],
    targets: [
        .target(
            name: "AINotepadCore",
            dependencies: [
                .product(name: "AINotepadWatchLink", package: "AINotepadWatchLink"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ]
        ),
        .target(name: "KeyboardCore"),
        .target(
            name: "AINotepadUI",
            dependencies: ["AINotepadCore"]
        ),
        // Tasarımı gözle kontrol etmek için örnek verilerle ada ve paneli açan geliştirme aracı (uygulamaya girmez).
        .executableTarget(
            name: "AINotepadPreview",
            dependencies: ["AINotepadUI", "AINotepadCore"]
        ),
        .testTarget(
            name: "AINotepadUITests",
            dependencies: ["AINotepadUI", "AINotepadCore"]
        ),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KeyboardCore"]
        ),
        .testTarget(
            name: "AINotepadCoreTests",
            dependencies: ["AINotepadCore", .product(name: "AINotepadWatchLink", package: "AINotepadWatchLink")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
