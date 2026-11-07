import AINotepadCore
import SwiftUI

/// Alt çizgili metin sekmeleri (toplantı sayfasının Özet/Transkript/Ekranlar seçicisi, Kişiler): seçili sekmenin altında
/// vurgu renginde çizgi kayar.
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

/// Karar ve açık konu satırındaki an: zaman çipi; ses varsa oynatma işaretiyle, tıklayınca oradan çalar (konu
/// akışındaki zamanla aynı görünüm).
public struct NoteTimeChip: View {
    let startSec: Double
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(startSec: Double, canPlay: Bool, onPlay: @escaping @MainActor (Double) -> Void) {
        self.startSec = startSec
        self.canPlay = canPlay
        self.onPlay = onPlay
    }

    public var body: some View {
        Button {
            onPlay(startSec)
        } label: {
            HStack(spacing: 4) {
                if canPlay {
                    Image(systemName: "play.fill")
                        .appFont(size: 8, weight: .bold)
                        .foregroundStyle(appearance.accent.color)
                }
                Text(timestamp(seconds: startSec))
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
        .fixedSize()
        .accessibilityLabel(Text("Buradan dinle"))
        .accessibilityValue(Text(verbatim: timestamp(seconds: startSec)))
    }
}
