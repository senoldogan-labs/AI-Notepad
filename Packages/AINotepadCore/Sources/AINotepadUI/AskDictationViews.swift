import AINotepadCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Sor alanındaki mikrofon düğmesi: boştayken dinlemeyi başlatır, dinlerken (vurgu renginde, onay işareti) bitirip metni
/// alana ekler, yazıya dökerken küçük ilerleme gösterir. Kayıt sürerken üstü çizili mikrofondur; dokununca nedeni
/// alanın üstünde görünür (`askDictationMeetingNotice`).
public struct AskMicButton: View {
    let dictation: AskDictation
    /// Bu soru alanının kimliği (`AskDictation.owner`).
    let owner: UUID
    /// Toplantı kaydı sürüyor ya da başlıyor: mikrofon kayıttadır.
    let isMeetingActive: Bool
    /// Görünen dairenin çapı.
    let diameter: CGFloat
    /// Dokunma alanının en küçük kenarı (iPhone'da 44 pt).
    let minTapSize: CGFloat
    /// Boştayken dairenin zemini (Mac'te saydam, iPhone'da soluk).
    let idleBackground: Color
    /// Bitince yazıya dökülen metin.
    let onText: @MainActor (String) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        dictation: AskDictation, owner: UUID, isMeetingActive: Bool, diameter: CGFloat, minTapSize: CGFloat, idleBackground: Color,
        onText: @escaping @MainActor (String) -> Void
    ) {
        self.dictation = dictation
        self.owner = owner
        self.isMeetingActive = isMeetingActive
        self.diameter = diameter
        self.minTapSize = minTapSize
        self.idleBackground = idleBackground
        self.onText = onText
    }

    public var body: some View {
        let phase: AskDictationPhase = dictation.phase(owner: owner)
        Button(action: tapped) {
            Group {
                switch phase {
                case .listening:
                    Image(systemName: "checkmark")
                        .appFont(size: diameter * 0.4, weight: .bold)
                        .foregroundStyle(appearance.accent.onFillColor)
                        .frame(width: diameter, height: diameter)
                        .background(appearance.accent.fillColor, in: Circle())
                case .preparing, .transcribing:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: diameter, height: diameter)
                case .idle, .notice:
                    Image(systemName: isMeetingActive ? "mic.slash" : "mic")
                        .appFont(size: diameter * 0.42, weight: .semibold)
                        .foregroundStyle(Theme.muted.opacity(isMeetingActive ? 0.6 : 1))
                        .frame(width: diameter, height: diameter)
                        .background(idleBackground, in: Circle())
                }
            }
            .frame(minWidth: minTapSize, minHeight: minTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .disabled(phase == .transcribing || isPreparing(phase: phase))
        .hoverHint(hint(phase: phase), alignment: .trailing, edge: .top)
        .accessibilityLabel(label(phase: phase))
        .accessibilityHint(hint(phase: phase))
    }

    private func tapped() {
        switch dictation.phase(owner: owner) {
        case .listening:
            dictation.finish()
        case .preparing, .transcribing:
            return
        case .idle, .notice:
            if isMeetingActive {
                dictation.show(notice: askDictationMeetingNotice(), owner: owner)
            } else {
                dictation.start(owner: owner, onText: onText)
            }
        }
    }

    private func isPreparing(phase: AskDictationPhase) -> Bool {
        if case .preparing = phase {
            return true
        }
        return false
    }

    private func label(phase: AskDictationPhase) -> LocalizedStringKey {
        switch phase {
        case .listening: "Bitir ve soruya ekle"
        case .preparing, .transcribing: "Yazıya dökülüyor…"
        case .idle, .notice: "Sesle sor"
        }
    }

    private func hint(phase: AskDictationPhase) -> LocalizedStringKey {
        switch phase {
        case .listening: "Söylediğin soru alanına eklenir; göndermeden önce düzeltebilirsin"
        case .preparing, .transcribing: "Söylediğin soru alanına ekleniyor"
        case .idle, .notice:
            isMeetingActive ? "Kayıt sürerken mikrofon toplantıda" : "Soruyu söyle; metin alana gelir, gönderilmez"
        }
    }
}

/// Soru alanının üstündeki sesle soru satırı (yalnız bu alan dinlerken ya da notu varken): dinlerken ses çubukları ve
/// akan ara metin (yoksa "Dinliyor…") ile bırak düğmesi; hazırlanırken ve yazıya dökerken kısa durum; not varsa
/// (izin yok, dil desteklenmiyor, kayıt sürüyor) not, mikrofon izni için "Ayarları aç" ve kapat. Not ve durum
/// VoiceOver'a duyurulur.
public struct AskDictationStatus: View {
    let dictation: AskDictation
    let owner: UUID
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(dictation: AskDictation, owner: UUID) {
        self.dictation = dictation
        self.owner = owner
    }

    public var body: some View {
        let phase: AskDictationPhase = dictation.phase(owner: owner)
        Group {
            switch phase {
            case .idle:
                EmptyView()
            case .listening:
                HStack(alignment: .center, spacing: 10) {
                    LevelMeter(levels: dictation.levels)
                    partialOr(placeholder: "Dinliyor…")
                    Spacer(minLength: 4)
                    closeButton(label: "Dinlemeyi bırak") { dictation.cancel() }
                }
            case .preparing(let progress):
                HStack(spacing: 8) {
                    if let progress {
                        ProgressView(value: progress)
                            .frame(width: 60)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Dikte modeli hazırlanıyor…")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 4)
                    closeButton(label: "Dinlemeyi bırak") { dictation.cancel() }
                }
            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    partialOr(placeholder: "Yazıya dökülüyor…")
                    Spacer(minLength: 4)
                }
            case .notice(let notice):
                // Not tam genişlikte sarılır (büyük yazıda da okunur); ayar düğmesi altında.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        NoticeText(notice.text, severity: notice.severity)
                            .appFont(size: 13, weight: .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        closeButton(label: "Kapat") { dictation.dismissNotice() }
                    }
                    if notice.opensMicrophoneSettings {
                        Button("Ayarları aç", action: openMicrophoneSettings)
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(appearance.accent.color)
                            .buttonStyle(.hoverPlain)
                            .padding(.leading, 20)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .transition(.opacity)
        .onChange(of: phase) { (_: AskDictationPhase, new: AskDictationPhase) in
            announce(phase: new)
        }
    }

    /// Ara metin (son iki satır, en yenisi görünür) ya da yer tutucu.
    @ViewBuilder
    private func partialOr(placeholder: LocalizedStringKey) -> some View {
        if dictation.partialText.isEmpty {
            Text(placeholder)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
        } else {
            Text(verbatim: dictation.partialText)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.ink.opacity(0.8))
                .lineLimit(2)
                .truncationMode(.head)
                .accessibilityLabel(Text(verbatim: dictation.partialText))
        }
    }

    private func closeButton(label: LocalizedStringKey, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .appFont(size: 10, weight: .bold)
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 24)
                .background(Theme.soft, in: Circle())
                .frame(minWidth: closeTapSize, minHeight: closeTapSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// Kapat düğmesinin dokunma alanı: iPhone'da 44 pt, Mac'te dairenin kendisi.
    private var closeTapSize: CGFloat {
        #if os(iOS)
        44
        #else
        24
        #endif
    }

    /// Dinleme başladı ya da not geldi: VoiceOver kullanıcısı odağı değiştirmeden duyar.
    private func announce(phase: AskDictationPhase) {
        switch phase {
        case .listening:
            AccessibilityNotification.Announcement(String(localized: "Dinliyor…")).post()
        case .notice(let notice):
            AccessibilityNotification.Announcement(notice.text).post()
        case .idle, .preparing, .transcribing:
            return
        }
    }

    /// Mikrofon izninin verildiği yer: Mac'te Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon, iPhone'da Ayarlar'daki
    /// uygulama sayfası.
    private func openMicrophoneSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            preconditionFailure("Mikrofon gizlilik ayarının adresi geçersiz")
        }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            preconditionFailure("Ayarlar adresi geçersiz")
        }
        UIApplication.shared.open(url)
        #endif
    }
}
