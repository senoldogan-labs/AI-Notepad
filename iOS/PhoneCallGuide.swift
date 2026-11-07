import AINotepadCore
import AINotepadUI
import os
import SwiftUI

/// Telefon görüşmesinin notunu almanın yolları (kayıt seçenekleri menüsünden ve kitaplıktan açılır).
///
/// iOS, uygulamaların süren bir aramanın mikrofonunu ve sesini almasına izin vermez (`AVAudioSession` etkinleştirmesi
/// `InsufficientPriority` ile reddedilir; bkz. docs/superpowers/specs/2026-11-08-iphone-call-recording.md). Bu yüzden
/// iPhone'daki yol, iPhone'un kendi arama kaydıdır: iPhone iki tarafa kaydı duyurur, kayıt Notlar'a düşer, kullanıcı sesi
/// paylaşım sayfasından Gistsmith'e gönderir (`PhoneSharedFileInbox`) ve toplantı yüz yüze kayıt gibi işlenir. Arama
/// kaydı her bölgede yoktur (ör. AB); orada ve uygulama aramalarında (WhatsApp, Teams, Zoom) yol Mac'tir.
struct PhoneCallGuideScreen: View {
    /// Rehberden seçilen seçici (Dosyalar); rehber kapanınca açılır.
    let onPick: @MainActor (PhoneImportSource) -> Void
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("iPhone, uygulamaların süren bir aramayı dinlemesine izin vermez. Görüşmeyi iPhone'un kendi arama kaydıyla kaydet ve sesi Gistsmith'e gönder; not, kararlar ve görevler yüz yüze kayıttaki gibi hazırlanır.")
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    NoticeText("Kaydetmeden önce karşı tarafa haber ver ve onayını al; birçok ülkede bu yasal zorunluluktur.", severity: .attention)
                        .appFont(size: 13, weight: .regular)
                    VStack(alignment: .leading, spacing: 10) {
                        PhoneSectionHeader(title: "iPhone'un arama kaydıyla", actionTitle: nil, action: nil)
                        CallRecordingStepsCard(onOpenNotes: openNotes, onPickFile: { pick(source: .files) })
                        Text("iOS 18.1 ya da sonrası gerekir. Arama kaydı her bölgede yok (ör. Avrupa Birliği); aramada kayıt düğmesi görünmüyorsa bölgende kullanılamıyordur. Sesli Notlar'daki ve diğer uygulamalardaki ses kayıtlarını da aynı yolla gönderebilirsin.")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        PhoneSectionHeader(title: "Mac'te konuşarak", actionTitle: nil, action: nil)
                        MacCallCard()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle(Text("Telefon görüşmesi"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// Notlar'ı açar (arama kayıtları "Arama Kayıtları" klasöründedir). Açılamazsa loglanır; düğme bir kısayoldur, adımlar
    /// metinde yazar.
    private func openNotes() {
        guard let url = URL(string: "mobilenotes://") else {
            return
        }
        openURL(url) { (accepted: Bool) -> Void in
            if !accepted {
                phoneCallGuideLogger.warning("Notlar açılamadı")
            }
        }
    }

    private func pick(source: PhoneImportSource) {
        onPick(source)
        dismiss()
    }
}

/// Arama kaydının bir adımı: sıra numarası, başlık ve tek cümle.
private struct CallRecordingStep: Identifiable {
    let id: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
}

/// Arama kaydının üç adımı (numaralı, çizgiyle bağlı) ve iki düğme: Notlar'ı aç, Dosyalar'dan seç.
private struct CallRecordingStepsCard: View {
    let onOpenNotes: @MainActor () -> Void
    let onPickFile: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private let steps: [CallRecordingStep] = [
        CallRecordingStep(id: 1, title: "Aramada kaydı başlat", detail: "Görüşme sırasında ekranın sol üstündeki kayıt düğmesine dokun. iPhone kaydın başladığını iki tarafa da duyurur."),
        CallRecordingStep(id: 2, title: "Sesi Gistsmith'e gönder", detail: "Görüşme bitince kaydı Notlar'da aç, sesi paylaş ve Gistsmith'i seç."),
        CallRecordingStep(id: 3, title: "Not hazır", detail: "Gistsmith konuşmacıları ayırır; notu, kararları ve görevleri yazar."),
    ]

    var body: some View {
        let accent: Color = appearance.accent.color
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { (step: CallRecordingStep) in
                    let isLast: Bool = step.id == steps.count
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            Text(verbatim: "\(step.id)")
                                .appFont(size: 14, weight: .semibold)
                                .foregroundStyle(accent)
                                .frame(width: 32, height: 32)
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
                        .padding(.top, 4)
                        .padding(.bottom, isLast ? 0 : 16)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 10) {
                Button { onOpenNotes() } label: {
                    Label { Text("Notlar'ı aç") } icon: { Image(systemName: "note.text") }
                }
                .buttonStyle(.accentPill)
                Button { onPickFile() } label: {
                    Label { Text("Dosyalar'dan seç") } icon: { Image(systemName: "folder") }
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.soft, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Text("Paylaşımda Gistsmith görünmüyorsa sesi Dosyalar'a kaydet ve buradan seç.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Mac'teki yol: iPhone aramaları ve uygulama aramaları (WhatsApp, Teams, Zoom) Mac'te yapılınca Gistsmith bilgisayarın
/// sesini ve mikrofonu kaydeder.
private struct MacCallCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AccentSymbolTile(symbol: "laptopcomputer", size: 40)
            Text("Arama kaydı olmayan bölgelerde ve WhatsApp, Teams, Zoom gibi uygulama aramalarında görüşmeyi Mac'te yap (iPhone aramaları da Mac'ten açılabilir). Mac'teki Gistsmith iki tarafı da kaydeder.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

private let phoneCallGuideLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneCallGuide")
