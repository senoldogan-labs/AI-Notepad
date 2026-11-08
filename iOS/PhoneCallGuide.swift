import AINotepadCore
import AINotepadUI
import os
import SwiftUI

/// Telefon görüşmesinin notunu almanın yolları (kayıt seçenekleri menüsünden, kitaplıktan ve Ayarlar › Özellikler'den
/// açılır).
///
/// iOS, uygulamaların süren bir aramanın mikrofonunu ve sesini almasına izin vermez (`AVAudioSession` etkinleştirmesi
/// `InsufficientPriority` ile reddedilir; bkz. docs/superpowers/specs/2026-11-08-iphone-call-recording.md). Bu yüzden
/// iPhone'daki yol, iPhone'un kendi arama kaydıdır: iPhone iki tarafa kaydı duyurur, kayıt Notlar'a düşer, kullanıcı sesi
/// paylaşım sayfasından Gistsmith'e gönderir (`PhoneSharedFileInbox`) ve toplantı yüz yüze kayıt gibi işlenir. Apple arama
/// kaydını her bölgede sunmaz (`callRecordingUnavailableRegions`, ör. AB); cihazın bölgesi o listedeyse rehber çalışan
/// yollarla başlar (Mac'te konuşmak, bir kaydı içe aktarmak) ve iPhone'un arama kaydını açık bir notla sonra gösterir.
/// Bölge yalnız sırayı değiştirir, hiçbir yolu gizlemez: Apple'ın sunumu dil ve başka ayarlara da bağlıdır.
struct PhoneCallGuideScreen: View {
    /// Rehberden seçilen seçici (Dosyalar); rehber kapanınca açılır.
    let onPick: @MainActor (PhoneImportSource) -> Void
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    /// Apple bu cihazın bölgesinde arama kaydını sunmuyor olabilir: Mac ve içe aktarma önce gelir.
    private let leadsWithAlternatives: Bool = callRecordingLikelyUnavailable(regionCode: Locale.current.region?.identifier)
    #if PHONE_DIALER
    @Environment(PhoneDialer.self) private var dialer: PhoneDialer
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder
    /// Tuş takımı rehberin gezinme yığınında açılır (`--arama` ile açık başlar).
    @State private var showsDialer: Bool = launchOpensDialer(arguments: CommandLine.arguments)
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    NoticeText("Kaydetmeden önce karşı tarafa haber ver ve onayını al; birçok ülkede bu yasal zorunluluktur.", severity: .attention)
                        .appFont(size: 13, weight: .regular)
                    #if PHONE_DIALER
                    // Uygulamadan arama yalnız sunucu bu hesaba ve ülkeye izin verince görünür (`PHONE_CALLS_POLICY`).
                    if dialer.isAvailable {
                        PhoneDialerCard(dialer: dialer) { showsDialer = true }
                    }
                    #endif
                    if leadsWithAlternatives {
                        macSection
                        importSection
                        unofferedCallRecordingSection
                    } else {
                        callRecordingSection
                        macSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle(Text("Telefon görüşmesi"))
            #if PHONE_DIALER
            .navigationDestination(isPresented: $showsDialer) { PhoneDialerScreen(dialer: dialer) }
            .task { await dialer.refresh(recorder: recorder) }
            #endif
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CloseToolbarButton { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// Giriş: iOS'un sınırı ve bu bölgede önce gelen yol.
    private var intro: Text {
        if leadsWithAlternatives {
            return Text("iPhone, uygulamaların süren bir aramayı dinlemesine izin vermez ve Apple iPhone'un arama kaydını bölgende sunmuyor olabilir. Görüşmeyi Mac'te yap ya da kaydını içe aktar; not, kararlar ve görevler yüz yüze kayıttaki gibi hazırlanır.")
        }
        return Text("iPhone, uygulamaların süren bir aramayı dinlemesine izin vermez. Görüşmeyi iPhone'un kendi arama kaydıyla kaydet ve sesi Gistsmith'e gönder; not, kararlar ve görevler yüz yüze kayıttaki gibi hazırlanır.")
    }

    /// iPhone'un arama kaydı, Apple'ın sunduğu bölgede: adımlar, Notlar ve Dosyalar düğmeleri.
    private var callRecordingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideSectionHeader(title: "iPhone'un arama kaydıyla")
            CallRecordingStepsCard {
                CallRecordingActions(onOpenNotes: openNotes, onPickFile: { pick(source: .files) })
            }
            GuideFootnote(text: "iOS 18.1 ya da sonrası gerekir. Arama kaydı her bölgede yok (ör. Avrupa Birliği); aramada kayıt düğmesi görünmüyorsa bölgende kullanılamıyordur. Sesli Notlar'daki ve diğer uygulamalardaki ses kayıtlarını da aynı yolla gönderebilirsin.")
        }
    }

    /// iPhone'un arama kaydı, Apple'ın sunmadığı bir bölgede: önce açık not, sonra aynı adımlar (dil ya da ayar başka
    /// olabilir) ve Notlar düğmesi; Dosyalar düğmesi içe aktarma kartında.
    private var unofferedCallRecordingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideSectionHeader(title: "iPhone'un arama kaydıyla")
            GuideFootnote(text: "Apple, iPhone'un arama kaydını bölgende sunmuyor olabilir (ör. Avrupa Birliği). Aramada kayıt düğmesi görünüyorsa bu adımlar çalışır; iOS 18.1 ya da sonrası gerekir.")
            CallRecordingStepsCard {
                Button { openNotes() } label: {
                    Label { Text("Notlar'ı aç") } icon: { Image(systemName: "note.text") }
                }
                .buttonStyle(.accentPill)
            }
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideSectionHeader(title: "Bir kaydı içe aktararak")
            ImportRecordingCard { pick(source: .files) }
        }
    }

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideSectionHeader(title: "Mac'te konuşarak")
            MacCallCard()
        }
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

/// Rehberdeki bir yolun başlığı (VoiceOver'da başlık).
private struct GuideSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        PhoneSectionHeader(title: title, actionTitle: nil, action: nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Bir yolun altındaki ya da üstündeki küçük açıklama.
private struct GuideFootnote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Arama kaydının bir adımı: sıra numarası, başlık ve tek cümle.
private struct CallRecordingStep: Identifiable {
    let id: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
}

/// Arama kaydının üç adımı (numaralı, çizgiyle bağlı) ve altında verilen düğmeler.
private struct CallRecordingStepsCard<Actions: View>: View {
    @ViewBuilder let actions: Actions
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
            actions
        }
        .guideCard()
    }
}

/// Arama kaydı adımlarının düğmeleri (Notlar'ı aç, Dosyalar'dan seç) ve paylaşımda Gistsmith yoksa ne yapılacağı.
private struct CallRecordingActions: View {
    let onOpenNotes: @MainActor () -> Void
    let onPickFile: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button { onOpenNotes() } label: {
                    Label { Text("Notlar'ı aç") } icon: { Image(systemName: "note.text") }
                }
                .buttonStyle(.accentPill)
                PickFileButton(action: onPickFile)
            }
            Text("Paylaşımda Gistsmith görünmüyorsa sesi Dosyalar'a kaydet ve buradan seç.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Dosyalar'dan seç": yumuşak zeminli kapsül düğme.
private struct PickFileButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button { action() } label: {
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
}

/// Başka bir yerde kaydedilmiş görüşmeyi içe aktarmak: paylaşım sayfasından Gistsmith'e gönder ya da Dosyalar'dan seç.
private struct ImportRecordingCard: View {
    let onPickFile: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AccentSymbolTile(symbol: "waveform", size: 40)
                Text("Görüşme başka bir cihazda ya da uygulamada kaydedildiyse sesi paylaşıp Gistsmith'i seç ya da Dosyalar'dan seç; not, yüz yüze kayıttaki gibi hazırlanır.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            PickFileButton(action: onPickFile)
        }
        .guideCard()
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
        .guideCard()
    }
}

private extension View {
    /// Rehberdeki kartların zemini: iç boşluk, kart rengi ve ince kenar.
    func guideCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

private let phoneCallGuideLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneCallGuide")
