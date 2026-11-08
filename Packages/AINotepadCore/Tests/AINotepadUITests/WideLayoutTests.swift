import Foundation
import Testing
@testable import AINotepadUI

/// Geniş ekran düzeninin eşikleri, iPhone Duo'nun belgelenen ölçüleriyle (Xcode 27.2 aygıt profili: dış ekran 1398×2034,
/// iç ekran 2007×2853 piksel, @3x).
@Suite struct WideLayoutTests {
    // Yalnız açılmış Duo'nun iç ekranı (dikey ve yan) yan yana düzene geçer; dış ekran, normal iPhone'lar ve Duo'daki
    // Split View'un yarım penceresi tek sütun kalır.
    @Test func onlyTheUnfoldedInnerDisplayIsWide() {
        #expect(usesWideLayout(isRegularWidth: true, width: 669))
        #expect(usesWideLayout(isRegularWidth: true, width: 951))
        #expect(!usesWideLayout(isRegularWidth: false, width: 466))
        #expect(!usesWideLayout(isRegularWidth: false, width: 440))
        #expect(!usesWideLayout(isRegularWidth: true, width: 334))
        // Boyut sınıfı "compact" iken genişlik ne olursa olsun tek sütun (ör. Pro Max yan çevrilmiş ama uygulama dikey).
        #expect(!usesWideLayout(isRegularWidth: false, width: 956))
    }

    // Kenar sütunu dikey Duo'da en az 280 pt; yan çevrilince 380 pt'de durur; içeriğe hep en az 360 pt kalır.
    @Test func sidebarLeavesRoomForTheDetail() {
        #expect(abs(wideSidebarWidth(containerWidth: 669) - 280.98) < 0.001)
        #expect(wideSidebarWidth(containerWidth: 951) == 380)
        #expect(wideSidebarWidth(containerWidth: 640) == 280)
        #expect(640 - wideSidebarWidth(containerWidth: 640) >= 360)
    }

    // "Notlarım" sütunu canlı metinden hep dar.
    @Test func notesColumnIsNarrowerThanTheTranscript() {
        for width in [640.0, 669, 800, 951] {
            let notes: Double = wideNotesColumnWidth(containerWidth: width)
            #expect(notes >= WideLayout.notesMinimumWidth)
            #expect(notes <= WideLayout.notesMaximumWidth)
            #expect(width - notes > notes)
        }
    }
}
