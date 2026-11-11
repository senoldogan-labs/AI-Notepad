#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import os
import SwiftUI

// Uygulamanın tek yazı sistemi (bu dosya ve `PanelAppearance.swift`). Arayüzdeki her yazı Ayarlar › Görünüm'deki yazı
// tipi ailesini, "Arayüz yazısı" ölçeğini, "Okuma metni" boyutunu ve iPhone'da Dinamik Yazı'yı bunlardan alır:
//
// - `appFont(size:weight:)`: arayüz yazısı (başlık, düğme, liste, etiket); boyut tasarımdaki puntodur, ölçekle çarpılır.
// - `readingText(size:weight:lineSpacing:)`: okuma metni (not, özet, transkript, cevap); "Okuma metni" ile orantılanır.
// - `appMonoFont(size:weight:)`: eş aralıklı yazı (kod, davet ve eşleme kodu, adres); aile değil ölçek uygulanır.
// - `shapeSymbol(size:weight:)`: sabit boyutlu kutucuk ya da kapaktaki simge; boyut şekle bağlıdır.
// - `platformFont(choice:points:weight:)`: AppKit/UIKit yazısı (Mac'te soru alanı, iPhone'da gezinme çubuğu başlığı).
// - `fontChoicePreview(choice:size:)`: yazı tipi seçicideki her satırın kendi yazısıyla önizlemesi.
//
// `SourceLintTests` (`raw-font`) bu iki dosya dışında `.font(.system(`, `.font(.custom(`, `Font.custom(` ve sistem metin
// stillerini (`.font(.callout)`) yasaklar. Belgelenmiş istisnalar testteki listededir: widget'lar ve Canlı Etkinlik
// (ayrı süreç, seçili aileyi okuyamaz; sistem metin stilleriyle Dinamik Yazı'yı izler) ve PDF/görsel çıktısı.
// Sistem uyarıları, bağlam menüleri, klavye ve paylaşım sayfası sistem yazısında kalır (uygulama değiştiremez).

#if os(macOS)
public typealias PlatformFont = NSFont
public typealias PlatformFontWeight = NSFont.Weight
#else
public typealias PlatformFont = UIFont
public typealias PlatformFontWeight = UIFont.Weight
#endif

/// Seçili ailede (Inter, SF tasarımı ya da yüklü aile) verilen puntoda AppKit/UIKit yazısı (punto ölçekli verilir: soru
/// alanında `size * uiScale`, gezinme başlığında `navigationTitleScale`). Aile yazıyı oluşturamazsa programcı hatasıdır
/// (aile `resolvedPanelAppearance` ile yüklü olanlara sıkıştırılır).
public func platformFont(choice: AppFontChoice, points: CGFloat, weight: PlatformFontWeight) -> PlatformFont {
    // AppKit/UIKit'in yazı tanımı sözlüğü türsüz değer ister (`[TraitKey: Any]`); başka biçimi yok.
    let traits: [PlatformFontDescriptor.TraitKey: Any] = [.weight: weight]
    let descriptor: PlatformFontDescriptor
    switch choice {
    case .design(.inter):
        descriptor = PlatformFontDescriptor(fontAttributes: [.family: Theme.interFamily, .traits: traits])
    case .design(let design):
        guard let designed = PlatformFont.systemFont(ofSize: points, weight: weight).fontDescriptor.withDesign(platformDesign(design: design)) else {
            preconditionFailure("Sistem yazısının tasarımı bulunamadı: \(design.rawValue)")
        }
        descriptor = designed
    case .installed(let family):
        descriptor = PlatformFontDescriptor(fontAttributes: [.family: family, .traits: traits])
    }
    #if os(macOS)
    guard let font = NSFont(descriptor: descriptor, size: points) else {
        preconditionFailure("Yazı oluşturulamadı: \(choice.storageValue)")
    }
    return font
    #else
    return UIFont(descriptor: descriptor, size: points)
    #endif
}

#if os(macOS)
private typealias PlatformFontDescriptor = NSFontDescriptor
#else
private typealias PlatformFontDescriptor = UIFontDescriptor
#endif

/// SF tasarımının AppKit/UIKit karşılığı. Saf fonksiyondur.
private func platformDesign(design: PanelFontDesign) -> PlatformFontDescriptor.SystemDesign {
    switch design {
    case .inter, .system: .default
    case .rounded: .rounded
    case .serif: .serif
    case .monospaced: .monospaced
    }
}

/// Uygulamanın Latin yazılı dillerinin (Türkçe, İngilizce, Fince, Almanca, Fransızca, İspanyolca, İtalyanca, Portekizce,
/// Felemenkçe, İskandinav dilleri) özel harfleri: seçilebilen yazı ailesi bunların hepsini kendisi çizmelidir.
public let appTextCharacters: String = "ÇçĞğİıÖöŞşÜüÂâÎîÛûÄäÅåÆæØøßÉéÈèÊêËëÀàÁáÃãÕõÔôÓóÒòÍíÌìÏïÚúÙùÑñŒœ€"

/// Ailenin normal yüzü `appTextCharacters`'ın hepsini içeriyor mu. Eksik harfi CoreText başka bir yazıdan (çoğu zaman
/// başka ağırlıkta) alır: iPhone'da Apple SD Gothic Neo, Gill Sans ve Optima "ş"yi kalın sistem yazısıyla çizer. Yüklü
/// olmayan aile false'tur (CoreText başka bir aile verir). Sonuç aile başına saklanır: yazı seçici her çizimde yüzlerce
/// aileyi sorar; yazılar yüklenip kaldırılınca `forgetFontCoverage()` saklananları siler.
public func fontFamilyCoversAppText(family: String) -> Bool {
    if let known = fontCoverageCache.withLock({ (cache: inout [String: Bool]) -> Bool? in cache[family] }) {
        return known
    }
    let covers: Bool = measuredFontFamilyCoversAppText(family: family)
    fontCoverageCache.withLock { (cache: inout [String: Bool]) -> Void in cache[family] = covers }
    return covers
}

/// Saklanan kapsama sonuçlarını siler: yüklü yazılar değişti (Mac'te `NSFont.fontSetChangedNotification`).
public func forgetFontCoverage() {
    fontCoverageCache.withLock { (cache: inout [String: Bool]) -> Void in cache.removeAll() }
}

/// Aile adı → `appTextCharacters`'ı kapsıyor mu (`fontFamilyCoversAppText`).
private let fontCoverageCache: OSAllocatedUnfairLock<[String: Bool]> = OSAllocatedUnfairLock(initialState: [:])

/// `fontFamilyCoversAppText`'in CoreText ölçümü (saklamadan).
private func measuredFontFamilyCoversAppText(family: String) -> Bool {
    let descriptor: CTFontDescriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
    let font: CTFont = CTFontCreateWithFontDescriptor(descriptor, 17, nil)
    guard CTFontCopyFamilyName(font) as String == family else {
        return false
    }
    let covered: CFCharacterSet = CTFontCopyCharacterSet(font)
    return appTextCharacters.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
        CFCharacterSetIsLongCharacterMember(covered, scalar.value)
    }
}

/// Yazı tipi seçicideki satırın kendi yazısıyla önizlemesi (ölçeksiz, normal ağırlık): Mac ve iPhone aynı.
public func fontChoicePreview(choice: AppFontChoice, size: CGFloat) -> Font {
    let standard: PanelAppearance = .standard
    return PanelAppearance(
        fontChoice: choice, uiScale: 1, textSize: standard.textSize, lineSpacing: standard.lineSpacing, bottomSpacing: standard.bottomSpacing,
        accent: standard.accent, surface: standard.surface, surfaceOpacity: standard.surfaceOpacity, boldText: false
    )
    .font(size: size, weight: .regular)
}

/// Sistemin "Kalın Metin" erişilebilirlik ayarında (iPhone) yazının iki kademe (~200 birim, SF gibi) kalın ağırlığı; ayar kapalıyken ağırlık
/// aynıdır. SF tasarımlarını sistem kendisi kalınlaştırır, bu yalnız gömülü ve yüklü aileler içindir. Saf fonksiyondur.
public func legibleWeight(weight: Font.Weight, legibility: LegibilityWeight?) -> Font.Weight {
    guard legibility == .bold else {
        return weight
    }
    let ladder: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
    guard let index = ladder.firstIndex(of: weight) else {
        return weight
    }
    return ladder[min(index + 2, ladder.count - 1)]
}

/// Görünüm ayarının varsayılana göre yüzdesi ("Arayüz yazısı: %110", "Okuma metni: %100"; Mac ve iPhone aynı). Saf
/// fonksiyondur.
public func appearancePercent(value: Double, reference: Double) -> Int {
    Int((value / reference * 100).rounded())
}

/// iPhone'un gezinme çubuğu başlığının ölçeği: kullanıcının "Arayüz yazısı" ayarı izlenir ama Dinamik Yazı çarpanıyla
/// ayar aralığının üstüne çıkmaz (sistem başlıkları da Dinamik Yazı'yla büyümez; satır içi başlık çubuğa sığmalı). Saf
/// fonksiyondur.
public func navigationTitleScale(uiScale: Double) -> Double {
    min(uiScale, AppearanceRange.uiScale.upperBound)
}

/// En büyük Dinamik Yazı çarpanı: erişilebilirlik boyutlarında düzen bozulmasın diye arayüz en çok iki kat büyür.
public let maximumDynamicTypeFactor: Double = 2

/// Dinamik Yazı'nın gövde metni boyutundan çarpan: sistemin bu boyuttaki gövde puntosu (`scaledBody`) varsayılan
/// gövde puntosuna (`defaultBody`, iPhone'da 17) oranlanır, en çok `maximumDynamicTypeFactor`. Saf fonksiyondur.
public func dynamicTypeFactor(scaledBody: Double, defaultBody: Double) -> Double {
    min(scaledBody / defaultBody, maximumDynamicTypeFactor)
}

/// Eş aralıklı yazı (bkz. `PanelAppearance.monoFont`).
private struct AppMonoFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    func body(content: Content) -> some View {
        content.font(appearance.monoFont(size: size, weight: weight))
    }
}

public extension View {
    /// Sabit boyutlu bir şeklin (simge kutucuğu, kapak) içindeki SF Symbol: boyut şekle bağlıdır, ölçekle büyümez (şekil
    /// büyümezken simge taşardı); semboller aileyi kullanmaz.
    func shapeSymbol(size: CGFloat, weight: Font.Weight) -> some View {
        font(.system(size: size, weight: weight))
    }

    /// Eş aralıklı yazı (kod, davet ve eşleme kodu, adres): SF Mono, arayüz ölçeğiyle (bkz. `PanelAppearance.monoFont`).
    func appMonoFont(size: CGFloat, weight: Font.Weight) -> some View {
        modifier(AppMonoFont(size: size, weight: weight))
    }
}
