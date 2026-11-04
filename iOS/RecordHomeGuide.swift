import AINotepadCore
import AINotepadUI
import SwiftUI

/// Henüz toplantı yokken kayıt kartının altı (Mac'teki "Henüz toplantı yok" sahnesiyle aynı hikâye): üç adımda nasıl
/// çalıştığı, takvim kapalıysa takvimi bağlama kartı ve kısa ipuçları (ad yazılmadıysa satır içinde ad alanı). Durgundur;
/// renkler kullanıcının vurgu rengidir.
struct RecordHomeGuide: View {
    let calendar: PhoneCalendar
    let store: PhoneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                PhoneSectionHeader(title: "Nasıl çalışır", actionTitle: nil, action: nil)
                HowItWorksCard()
            }
            if calendar.state == .off {
                CalendarConnectCard(calendar: calendar)
            }
            VStack(alignment: .leading, spacing: 10) {
                PhoneSectionHeader(title: "İpuçları", actionTitle: nil, action: nil)
                TipsCard(store: store)
            }
        }
    }
}

/// Bir adım: simge, başlık ve tek cümle.
private struct GuideStep: Identifiable {
    let id: Int
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
}

/// Üç adım alt alta: vurgu renkli simge yuvarlakları ince bir çizgiyle bağlı (kayıt → not → soru).
private struct HowItWorksCard: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private let steps: [GuideStep] = [
        GuideStep(id: 0, symbol: "mic.fill", title: "Odada kaydet", detail: "Telefonu masaya koy ve dokun; odadaki herkes konuşmacılara ayrılır."),
        GuideStep(id: 1, symbol: "checklist", title: "Not, kararlar, görevler", detail: "Bitince not hazır: kararlar ve sana düşen işler en üstte."),
        GuideStep(id: 2, symbol: "sparkle.magnifyingglass", title: "Toplantılarına sor", detail: "“Bütçe ne oldu?” diye sor; cevap hangi toplantıdan geldiğini gösterir."),
    ]

    var body: some View {
        let accent: Color = appearance.accent.color
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { (step: GuideStep) in
                let isLast: Bool = step.id == steps.count - 1
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Image(systemName: step.symbol)
                            .appFont(size: 14, weight: .semibold)
                            .foregroundStyle(accent)
                            .frame(width: 36, height: 36)
                            .background(accent.opacity(0.12), in: Circle())
                        if !isLast {
                            Rectangle()
                                .fill(accent.opacity(0.22))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                                .padding(.vertical, 4)
                        }
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .appFont(size: 15, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                        Text(step.detail)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                    .padding(.bottom, isLast ? 0 : 18)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Takvim kapalıyken: sıradaki toplantıların burada görüneceğini anlatan kart ve "Takvimi bağla" (iOS izni sorar;
/// verilmezse kart yerine izin uyarısı görünür).
private struct CalendarConnectCard: View {
    let calendar: PhoneCalendar
    @State private var isRequesting: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AccentSymbolTile(symbol: "calendar", size: 40)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Takvimini bağla")
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text("Sıradaki toplantıların burada görünür; o sırada başlattığın kayıt toplantının adını ve katılımcılarını alır.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    isRequesting = true
                    Task {
                        await calendar.enable()
                        isRequesting = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isRequesting {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text("Takvimi bağla")
                    }
                }
                .buttonStyle(.accentPill)
                .disabled(isRequesting)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Kısa ipuçları: adın (yazılmadıysa satır içinde alan), işaretleme, kendi notların ve Denetim Merkezi'nden başlatma.
private struct TipsCard: View {
    /// Ad hesabın ayar alanına yazılır (bkz. `PhoneStore.userName`).
    let store: PhoneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NameTipRow { (name: String) -> Void in store.setUserName(name: name) }
                divider
            }
            TipRow(symbol: "bookmark", title: "Önemli anı işaretle", detail: "Kayıtta “İşaretle”ye dokun; o an notta öne çıkar.")
            divider
            TipRow(symbol: "square.and.pencil", title: "Kendi notunu ekle", detail: "Kayıtta “Notlarım”a yazdıklarını not öncelik sayar.")
            divider
            TipRow(symbol: "switch.2", title: "Tek dokunuşla başlat", detail: "Denetim Merkezi'ne ya da Kısayollar'a Gistsmith kaydını ekle.")
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 62)
    }
}

/// İpucu satırı: vurgu renkli simge kutusu, başlık ve tek cümle.
private struct TipRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AccentSymbolTile(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Ad yazılmadıysa: notta senin görevlerinin ayrılması için satır içinde ad alanı; kaydedilince satır kalkar.
private struct NameTipRow: View {
    let onSave: @MainActor (String) -> Void
    @State private var name: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AccentSymbolTile(symbol: "person.crop.circle", size: 34)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adını yaz")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Text("Notta sana düşen görevler ayrılır.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 8) {
                    TextField("Adın", text: $name)
                        .appFont(size: 15, weight: .regular)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.soft, in: Capsule())
                    Button("Kaydet", action: save)
                        .buttonStyle(.accentPill)
                        .controlSize(.small)
                        .disabled(trimmed.isEmpty)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmed.isEmpty else {
            return
        }
        onSave(trimmed)
    }
}
