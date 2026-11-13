import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit

/// Settings › Apple Watch: the watch mockup and what to do next, from the session's pairing and installation
/// (`watchSetupState` over `PhoneWatchLink.sessionFacts`; it follows pairing and installation changes live).
struct PhoneWatchSettingsScreen: View {
    @Environment(PhoneWatchLink.self) private var watchLink: PhoneWatchLink

    var body: some View {
        ScrollView {
            WatchSetupPanel(state: shownState)
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }

    private var shownState: WatchSetupState {
        #if DEBUG
        // `--saat-durumu <durum>` (Debug only, visual check): the page in that state.
        if let state = launchWatchSetupState(arguments: CommandLine.arguments) {
            return state
        }
        #endif
        return watchSetupState(facts: watchLink.sessionFacts, requiredMajorVersion: watchAppMinimumPhoneSystemMajorVersion)
    }
}

#if DEBUG
/// `--saat-durumu yok|kur|hazir|ios|araniyor` (Debug only): the Apple Watch page in that state (the Simulator has no
/// paired watch); nil without the flag or with an unknown value. Pure function.
func launchWatchSetupState(arguments: [String]) -> WatchSetupState? {
    guard let index = arguments.firstIndex(of: "--saat-durumu"), arguments.indices.contains(index + 1) else {
        return nil
    }
    switch arguments[index + 1] {
    case "yok": return .noWatchPaired
    case "kur": return .appNotInstalled
    case "hazir": return .ready
    case "ios": return .needsNewerSystem(requiredMajorVersion: watchAppMinimumPhoneSystemMajorVersion)
    case "araniyor": return .checking
    default: return nil
    }
}
#endif

/// Settings › Share Gistsmith (also from the invite section in Plan and billing): a branded QR code of the account's
/// invite link (or the site link with a campaign tag, `shareAppLink`) and the system share sheet with the app's name and
/// icon as its preview. Like the invite section, the text speaks of the app only: no price, discount or web purchase
/// (App Store 3.1.1, 3.1.3).
struct PhoneShareAppScreen: View {
    let account: HostedAccount

    var body: some View {
        let invite: HostedReferralInvite? = phoneShareInvite(account: account)
        let link: URL = shareAppLink(inviteURL: invite?.url)
        let icon: UIImage? = bundleAppIcon(bundle: Bundle.main)
        ScrollView {
            VStack(spacing: 24) {
                ShareAppQRCard(link: link, icon: icon.map { Image(uiImage: $0) })
                    .frame(maxWidth: 300)
                    .padding(.top, 8)
                VStack(spacing: 8) {
                    Text("Arkadaşın iPhone kamerasıyla tarasın")
                        .appFont(size: 20, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Group {
                        if let invite {
                            Text("Kod davet bağlantını açar; katılan arkadaşların Plan ve faturalandırma'da sayılır. Davet kodun: \(invite.code)")
                        } else {
                            Text("Kod Gistsmith'in sitesini açar.")
                        }
                    }
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.muted)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                shareButton(link: link, icon: icon)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Gistsmith'i paylaş")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The share sheet's preview carries the app's name and icon (the system shows them at the top of the sheet).
    @ViewBuilder
    private func shareButton(link: URL, icon: UIImage?) -> some View {
        let title: Text = Text("Gistsmith – Yapay zekâ toplantı notları")
        let message: Text = Text("Toplantılarım için Gistsmith kullanıyorum: konuşulanı canlı yazıya döküyor, toplantı bitince notu ve görevleri hazırlıyor.")
        Group {
            if let icon {
                ShareLink(item: link, subject: title, message: message, preview: SharePreview(title, image: Image(uiImage: icon))) {
                    PhonePrimaryButtonLabel(title: "Bağlantıyı paylaş")
                }
            } else {
                ShareLink(item: link, subject: title, message: message, preview: SharePreview(title)) {
                    PhonePrimaryButtonLabel(title: "Bağlantıyı paylaş")
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The account's invite link and code when it has one (`PhoneReferralSection` shows the same); nil otherwise.
struct HostedReferralInvite: Equatable {
    let url: URL
    let code: String
}

/// The loaded account's invite (enabled, with code and link), or nil.
@MainActor
func phoneShareInvite(account: HostedAccount) -> HostedReferralInvite? {
    guard let referral = account.referral, referral.enabled, let code = referral.code, let url = referral.inviteUrl else {
        return nil
    }
    return HostedReferralInvite(url: url, code: code)
}
