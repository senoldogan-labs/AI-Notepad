import AINotepadCore
import SwiftUI

/// Toplantı notunun sekmeli bölümleri (Mac ve iPhone özetinde aynı): görevler, konu akışı, kararlar, işaretli anlar.
/// Boş bölümün sekmesi gösterilmez.
public enum NoteSectionTab: String, Sendable, CaseIterable, Hashable {
    case tasks
    case outline
    case decisions
    case moments
}

/// Gösterilecek sekme: istenen sekme doluysa o, değilse ilk dolu sekme; hiçbiri dolu değilse nil. Saf fonksiyondur.
public func visibleNoteSection(requested: NoteSectionTab, available: [NoteSectionTab]) -> NoteSectionTab? {
    available.contains(requested) ? requested : available.first
}

/// Sekme başlığı ve sayısı: "Görevler · 7".
public func noteSectionTitle(tab: NoteSectionTab, count: Int) -> LocalizedStringKey {
    switch tab {
    case .tasks: "Görevler · \(count)"
    case .outline: "Konu akışı · \(count)"
    case .decisions: "Kararlar · \(count)"
    case .moments: "İşaretli anlar · \(count)"
    }
}

/// Açılıp kapanan grup: başlık satırı (ok, başlık, sayı, sağda isteğe bağlı bilgi) ve içerik. Başlığa tıklayınca içerik
/// kayarak açılır ya da kapanır.
public struct CollapsibleGroup<Content: View>: View {
    let title: LocalizedStringKey
    let count: Int
    /// Sağdaki soluk bilgi (ör. "1/3 tamamlandı"); yoksa nil.
    let detail: String?
    /// Sayı rozetinin rengi (ör. kullanıcının görevlerinde vurgu rengi); nil ise soluk.
    let tint: Color?
    @Binding var isExpanded: Bool
    let content: () -> Content

    public init(title: LocalizedStringKey, count: Int, detail: String?, tint: Color?, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self.detail = detail
        self.tint = tint
        self._isExpanded = isExpanded
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).appFont(size: 14, weight: .semibold)
                    Text(verbatim: "\(count)")
                        .appFont(size: 12, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(tint ?? Theme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(tint.map { $0.opacity(0.14) } ?? Theme.soft, in: Capsule())
                    Spacer(minLength: 8)
                    if let detail {
                        Text(verbatim: detail)
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? Text("Genişletilmiş") : Text("Daraltılmış"))
            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

/// Notun bölüm sekmeleri: alt çizgili metin sekmeleri (sayfanın Özet/Transkript hap seçicisinden ayrı bir düzey: sekme
/// içinde sekme gibi okunmaz). Seçili sekmenin altında vurgu renginde çizgi kayar.
public struct UnderlineTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Namespace private var underline: Namespace.ID

    public init(selection: Binding<Value>, options: [(value: Value, title: LocalizedStringKey)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: (value: Value, title: LocalizedStringKey))) in
                let isSelected: Bool = item.element.value == selection
                Button {
                    selection = item.element.value
                } label: {
                    Text(item.element.title)
                        .appFont(size: 14, weight: isSelected ? .semibold : .regular)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Capsule().fill(appearance.accent.color).frame(height: 2)
                                    .matchedGeometryEffect(id: "alt-cizgi", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .animation(.smooth(duration: 0.25), value: selection)
    }
}

/// Satırları ince çizgilerle ayrılmış tek yüzey (kart içinde kart yok): görev ve karar listeleri. `tint` verilirse
/// yüzey o rengin çok açık tonunda ve ince çerçevesi o renkte (kullanıcının görevleri öne çıksın).
public struct HairlineList<Item, Row: View>: View {
    let items: [Item]
    let tint: Color?
    let row: (Item) -> Row

    public init(items: [Item], tint: Color?, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.tint = tint
        self.row = row
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { (item: (offset: Int, element: Item)) in
                if item.offset > 0 {
                    Rectangle().fill(tint.map { $0.opacity(0.18) } ?? Theme.line).frame(height: 1).padding(.leading, 14)
                }
                row(item.element)
            }
        }
        .background {
            if let tint {
                shape.fill(Theme.card).overlay(shape.fill(tint.opacity(0.05)))
            }
        }
        .overlay {
            if let tint {
                shape.strokeBorder(tint.opacity(0.28))
            }
        }
        .modifier(PlainCardSurface(isOn: tint == nil))
    }
}

/// Renksiz listede kart yüzeyi (renkli listede zemin ve çerçeve `HairlineList`'in kendisinde).
private struct PlainCardSurface: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.cardSurface(cornerRadius: 14)
        } else {
            content
        }
    }
}

/// Konu akışı: zaman çizelgesinde konular. Kısa akışta (en çok `outlineOpenLimit` konu) özetler açık başlar, uzunda
/// kapalı; kapalı konu başlığının altında özetin ilk satırı görünür. Satıra tıklayınca özet açılır ya da kapanır, üstteki
/// düğme hepsini açar ya da kapatır. Zamana tıklayınca (ses varsa) oradan çalar.
public struct OutlineTimeline: View {
    let items: [OutlineItem]
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @State private var expanded: Set<Int>
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(items: [OutlineItem], canPlay: Bool, onPlay: @escaping @MainActor (Double) -> Void) {
        self.items = items
        self.canPlay = canPlay
        self.onPlay = onPlay
        _expanded = State(initialValue: items.count <= outlineOpenLimit ? Set(items.indices) : [])
    }

    public var body: some View {
        let allOpen: Bool = expanded.count == items.count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 0)
                Button(allOpen ? "Tümünü kapat" : "Tümünü aç", systemImage: "chevron.up.chevron.down") {
                    withAnimation(.smooth(duration: 0.25)) {
                        expanded = allOpen ? [] : Set(items.indices)
                    }
                }
                .buttonStyle(.hoverPlain)
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { (item: (offset: Int, element: OutlineItem)) in
                    row(index: item.offset, item: item.element, isLast: item.offset == items.count - 1)
                }
            }
        }
    }

    private func row(index: Int, item: OutlineItem, isLast: Bool) -> some View {
        let isOpen: Bool = expanded.contains(index)
        return HStack(alignment: .top, spacing: 12) {
            // Zaman ve zaman çizelgesi: çizgi bir sonraki konuya kesintisiz iner.
            VStack(spacing: 0) {
                Button {
                    onPlay(item.startSec)
                } label: {
                    HStack(spacing: 4) {
                        if canPlay {
                            Image(systemName: "play.fill")
                                .appFont(size: 8, weight: .bold)
                                .foregroundStyle(appearance.accent.color)
                        }
                        Text(timestamp(seconds: item.startSec))
                            .appFont(size: 12, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.soft, in: Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .disabled(!canPlay)
                .accessibilityLabel(Text("Buradan dinle"))
                if !isLast {
                    Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 64)
            Button {
                withAnimation(.smooth(duration: 0.22)) {
                    if isOpen {
                        expanded.remove(index)
                    } else {
                        expanded.insert(index)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .appFont(size: 10, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(appearance.readingFont(size: appearance.textSize, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.summary)
                            .font(appearance.secondaryFont)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.leading)
                            .lineLimit(isOpen ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, isLast ? 0 : 18)
                .frame(minHeight: 32, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? Text("Genişletilmiş") : Text("Daraltılmış"))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Konu akışı en çok bu kadar konuysa özetler açık başlar.
private let outlineOpenLimit: Int = 6
