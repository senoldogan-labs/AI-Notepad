import AINotepadCore
import AINotepadUI
import os
import SwiftUI

private let consentViewsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAIConsent")

/// The privacy policy on the site; nil (no link, error logged) when the site address is invalid.
private func consentPrivacyURL() -> URL? {
    do {
        return try HostedServices.siteBase().appending(path: "privacy")
    } catch {
        consentViewsLogger.error("Site address invalid, privacy link hidden, error: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// The third-party AI disclosure on the Mac (App Review 5.1.1(i) / 5.1.2(i); the iPhone's `PhoneAIDisclosure`): the main
/// window shows only this after sign-in until the account answers, and again when an AI feature is used without consent
/// (`HostedAIConsentCenter.isPromptRequested`). A card on the sign-in gate's static film backdrop: what goes to which service
/// and why, how it is protected, the privacy policy, "Kabul ediyorum" and "Şimdi değil". The service names are never
/// translated (same text as the privacy policy, section 3).
struct HostedAIConsentScreen: View {
    let consent: HostedAIConsentCenter
    @State private var isAgreeing: Bool = false

    var body: some View {
        ZStack {
            FilmGradient(seed: "gistsmith-aciklama", palette: .violet)
                .ignoresSafeArea()
            ScrollView {
                card
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "lock.shield.fill")
                .appFont(size: 22, weight: .regular)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text("Yapay zekâ hizmetleri ve verin")
                .appTitleFont(size: 26, weight: .regular)
                .tracking(-0.5)
                .foregroundStyle(Theme.ink)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text("Gistsmith toplantılarını yazıya dökmek, not yazmak ve sorularını cevaplamak için aşağıdaki üçüncü taraf yapay zekâ hizmetlerine veri gönderir. Onay vermeden hiçbir şey gönderilmez.")
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HostedAIConsentDetails()
                .padding(.top, 22)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
                .padding(.top, 22)
            if let message = consent.errorMessage {
                NoticeText(message, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            HStack(spacing: 10) {
                if let privacy = consentPrivacyURL() {
                    Link(destination: privacy) {
                        Label("Gizlilik politikasını oku", systemImage: "arrow.up.right")
                    }
                    .appFont(size: 13, weight: .semibold)
                }
                Spacer(minLength: 12)
                Button("Şimdi değil") { consent.decline() }
                    .buttonStyle(.pill)
                    .disabled(isAgreeing)
                Button("Kabul ediyorum") {
                    isAgreeing = true
                    Task {
                        await consent.grant()
                        isAgreeing = false
                    }
                }
                .buttonStyle(.accentPill)
                .keyboardShortcut(.defaultAction)
                .disabled(isAgreeing)
            }
            .padding(.top, 16)
            Text("Onay vermezsen hiçbir şey gönderilmez: kayıt, Sor ve notlar kapalı kalır, toplantılarını yine açabilirsin.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(32)
        // Smallest width: macOS proposes zero width when sizing the window; fixed texts would break letter by letter.
        .frame(minWidth: 420, idealWidth: 560, maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.12), radius: 30, y: 14)
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.line.opacity(0.6)))
    }
}

/// What goes to which service and how it is protected (the disclosure and Settings show the same rows).
struct HostedAIConsentDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(
                symbol: "waveform", name: Text(verbatim: "Deepgram"), purpose: "Canlı metin",
                text: "Kayıt sırasında toplantının sesi, canlı metin için doğrudan bu Mac'ten gönderilir."
            )
            row(
                symbol: "person.2.wave.2", name: Text(verbatim: "ElevenLabs"), purpose: "Transkript ve konuşmacılar",
                text: "Toplantı bitince kaydın sesi ve içe aktardığın ses ya da video dosyaları, konuşmacılara ayrılmış transkript için sunucumuz üzerinden gönderilir."
            )
            row(
                symbol: "sparkles", name: Text(verbatim: "Anthropic (Claude)"), purpose: "Not, çeviri ve cevaplar",
                text: "Transkript, notlar ve kendi notların; Sor'a yazdığın ya da Siri ve Kısayollar'la sorduğun sorular; eklediğin kişi adları ve terimler; ayarı açarsan notta kullanılan ekran görüntüleri ve fotoğraflar sunucumuz üzerinden gönderilir. Sor'da web araması açıksa aramayı da Anthropic yapar."
            )
            row(
                symbol: "hand.raised.fill", name: Text("Korunması"), purpose: nil,
                text: "Sunucumuz ses saklamaz. Bu hizmetler verini yalnızca bizim için işler, modellerini eğitmekte kullanmaz ve sınırlı bir süre sonra siler; gizlilik politikamızdakiyle aynı ya da eşdeğer koruma sağlar. Onayını istediğin zaman Ayarlar › Veri ve gizlilik'ten geri çekebilirsin."
            )
        }
    }

    private func row(symbol: String, name: Text, purpose: LocalizedStringKey?, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .appFont(size: 14, weight: .semibold)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                name.appFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink)
                if let purpose {
                    Text(purpose).appFont(size: 12, weight: .semibold).foregroundStyle(.tint)
                }
                Text(text)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Settings › Veri ve gizlilik › "Yapay zekâ hizmetleri": the state, the disclosure (to read again), "Oku ve onayla"
/// (opens the disclosure) or withdraw (asks first).
struct HostedAIConsentSettingsRow: View {
    let consent: HostedAIConsentCenter
    /// A recording or AI job runs: withdrawing waits (an open live transcript stream would keep sending audio).
    let isBusy: Bool
    @State private var isConfirmingWithdrawal: Bool = false
    @State private var isWorking: Bool = false

    var body: some View {
        SettingsRow(icon: "lock.shield", title: Text("Yapay zekâ hizmetleri")) {
            VStack(alignment: .leading, spacing: 4) {
                if consent.isGranted {
                    Text("Açık: ses ve metin Deepgram, ElevenLabs ve Anthropic'e gider.")
                } else {
                    Text("Kapalı: kayıt, Sor ve notlar için onay gerekir.")
                }
                Button("Neyin nereye gittiğini gör") { consent.requestPrompt() }
                    .buttonStyle(.link)
                if let message = consent.errorMessage {
                    NoticeText(message, severity: .error)
                }
                if consent.isGranted, isBusy {
                    Text("Kayıt ya da yapay zekâ işi sürerken onay geri çekilemez; bitince geri çekebilirsin.")
                }
            }
        } control: {
            if consent.isGranted {
                Button("Onayı geri çek") { isConfirmingWithdrawal = true }
                    .disabled(isWorking || isBusy)
            } else {
                // Agreeing always goes through the full disclosure (informed consent, 5.1.2(i)).
                Button("Oku ve onayla") { consent.requestPrompt() }
                    .disabled(isWorking)
            }
        }
        .confirmationDialog("Onay geri çekilsin mi?", isPresented: $isConfirmingWithdrawal) {
            Button("Onayı geri çek", role: .destructive) {
                isWorking = true
                Task {
                    await consent.withdraw()
                    isWorking = false
                }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Kayıt, Sor ve notlar hemen durur; bekleyen kayıtlar bu Mac'te kalır ve yeniden onay verince işlenir.")
        }
    }
}
