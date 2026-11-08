import SwiftUI

// iOS 18–25 karşılıkları: uygulama iOS 18'den itibaren çalışır; iOS 26'nın yeni API'leri burada tek yerde koşullanır.
// iOS 26+ sistem görünümünü (Liquid Glass, kapat düğmesi) olduğu gibi kullanır; eski sürümde standart karşılığı görünür.

/// Sayfayı kapatan araç çubuğu düğmesi: iOS 26+ sistemin kapat düğmesi (`role: .close`), eski sürümde aynı yerde
/// "Kapat" adlı x simgeli düğme.
struct CloseToolbarButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(action: action) {
                Label("Kapat", systemImage: "xmark")
            }
        }
    }
}

/// Bir modu bitiren araç çubuğu düğmesi ("Bitti"): iOS 26+ sistemin onay düğmesi (`role: .confirm`, vurgulu onay
/// işareti), eski sürümde iOS 18'in standart kalın "Bitti" metin düğmesi.
struct ConfirmToolbarButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .confirm, action: action) {
                Label("Bitti", systemImage: "checkmark")
            }
        } else {
            Button(action: action) {
                Text("Bitti")
                    .fontWeight(.semibold)
            }
        }
    }
}

extension View {
    /// Yüzen yüzey: iOS 26+ Liquid Glass (`glassEffect(.regular)`), eski sürümde aynı biçimde standart malzeme
    /// (`.regularMaterial`), ince kenar ve hafif gölge (cam gibi içeriğin üstünde ayrışır).
    @ViewBuilder
    func glassSurface(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            materialSurface(in: shape)
        }
    }

    /// Dokunulan yüzen düğmenin yüzeyi: iOS 26+ etkileşimli cam (`.regular.interactive()`), eski sürümde
    /// `glassSurface` ile aynı malzeme (basılma görünümünü düğme stili verir).
    @ViewBuilder
    func interactiveGlassSurface(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            materialSurface(in: shape)
        }
    }

    /// Arama alanı: iOS 26+ alt araç çubuğunda (sistemin arama yeri), eski sürümde gezinme çubuğunun altında (iOS 18'in
    /// standart yeri; `searchable` onu kendisi koyar).
    @ViewBuilder
    func searchFieldInBottomBar() -> some View {
        if #available(iOS 26.0, *) {
            toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
        } else {
            self
        }
    }

    /// Kayan içerik üst kenarda sert biter (iOS 26'nın yumuşak kenar efekti başlığın arkasında yarı saydam gösterirdi).
    /// iOS 18–25'te bu efekt yok: gezinme çubuğu standart malzemesiyle zaten sert biter.
    @ViewBuilder
    func hardTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }

    private func materialSurface(in shape: some Shape) -> some View {
        background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    }
}
