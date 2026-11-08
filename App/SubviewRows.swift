import SwiftUI

/// Bir `@ViewBuilder` içeriğinin satırları (ayar kartı satırlar arasına çizgi koyar, hiç satır yoksa kartı gizler):
/// sırayla, kimlikleriyle; her biri bir görünüm. macOS 15+ `SubviewsCollection` (`Group(subviews:)`), macOS 14'te
/// `_VariadicView.Children` (`LegacySubviews`).
protocol ViewRows: RandomAccessCollection where Element: View & Identifiable {}

@available(macOS 15.0, *)
extension SubviewsCollection: ViewRows {}

extension _VariadicView.Children: ViewRows {}

/// macOS 14'te `Group(subviews:)`'un karşılığı: `content`'i satırlarına ayırıp `transform`'a verir. SwiftUI'nin macOS
/// 10.15'ten beri kendi kullandığı, alt çizgili ama kararlı `_VariadicView.Tree` arayüzüyle; koşullu ve `ForEach`
/// satırları tek tek satır olur, gizli satır sayılmaz (macOS 15'teki gibi).
struct LegacySubviews<Content: View, Result: View>: View {
    let content: Content
    let transform: (_VariadicView.Children) -> Result

    init(of content: Content, @ViewBuilder transform: @escaping (_VariadicView.Children) -> Result) {
        self.content = content
        self.transform = transform
    }

    var body: some View {
        _VariadicView.Tree(LegacySubviewsRoot(transform: transform)) {
            content
        }
    }
}

private struct LegacySubviewsRoot<Result: View>: _VariadicView_MultiViewRoot {
    let transform: (_VariadicView.Children) -> Result

    func body(children: _VariadicView.Children) -> some View {
        transform(children)
    }
}
