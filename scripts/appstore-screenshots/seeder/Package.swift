// swift-tools-version: 6.2
import PackageDescription

// App Store ekran görüntüleri için örnek toplantıları ve Sor sohbetini uygulamanın kendi tipleriyle (AINotepadCore)
// diske yazan araç. Biçim değişirse derleme hatası verir; elle yazılmış JSON gibi sessizce bozulmaz.
let package = Package(
    name: "AppStoreSeeder",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../Packages/AINotepadCore"),
    ],
    targets: [
        .executableTarget(
            name: "AppStoreSeeder",
            dependencies: [.product(name: "AINotepadCore", package: "AINotepadCore")]
        ),
    ]
)
