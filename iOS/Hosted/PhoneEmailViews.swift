import AINotepadCore
import AINotepadUI
import SwiftUI

// Opt-in tips and reminder emails on the iPhone (state in App/Hosted/HostedEmailTips.swift, shared with the Mac): a section
// in Settings › Account and a one-time card on the main screen after sign-in. Both show only while the server offers it.

/// Settings › Account: the switch, the address field while opting in, the pending or confirmed address.
struct PhoneEmailTipsSection: View {
    let tips: HostedEmailTips
    @State private var isEditing: Bool = false
    @State private var address: String = ""

    var body: some View {
        if let state = tips.state, state.available || state.status != .off {
            Section {
                Toggle("Bana ipuçlarını ve denemem bitmeden bir hatırlatmayı e-postayla gönder", isOn: Binding<Bool>(
                    get: { state.status != .off || isEditing },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            isEditing = true
                        } else if state.status == .off {
                            isEditing = false
                            address = ""
                        } else {
                            isEditing = false
                            Task { await tips.withdraw() }
                        }
                    }
                ))
                .disabled(tips.isWorking)
                if isEditing {
                    PhoneEmailAddressField(tips: tips, address: $address) {
                        isEditing = false
                        address = ""
                    }
                } else if state.status != .off {
                    if state.status == .pending, let pending = state.pendingAddress {
                        Button("Yeniden gönder") { Task { _ = await tips.optIn(address: pending) } }
                            .disabled(tips.isWorking)
                    }
                    Button("Adresi değiştir") {
                        address = ""
                        isEditing = true
                    }
                    .disabled(tips.isWorking)
                }
                if let message = tips.errorMessage {
                    NoticeText(message as String, severity: .error)
                }
            } header: {
                PhoneSecondaryText {
                    Text("E-posta ipuçları")
                }
            } footer: {
                PhoneSecondaryText {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: hostedEmailStatusText(state: state))
                        if isEditing || state.status != .off {
                            Text(verbatim: hostedEmailPrivacyText())
                            Link(destination: hostedEmailPrivacyURL) { Text("Gizlilik politikası").underline() }
                        }
                    }
                }
            }
        }
    }
}

/// The address field and its button (Settings › Account and the main screen's card). `onSent` runs after the server
/// sent the confirmation link.
struct PhoneEmailAddressField: View {
    let tips: HostedEmailTips
    @Binding var address: String
    let onSent: @MainActor () -> Void

    var body: some View {
        TextField("E-posta adresin", text: $address)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.send)
            .onSubmit { send() }
        Button("Onay bağlantısı gönder") { send() }
            .disabled(tips.isWorking || !hostedEmailAddressLooksValid(address))
    }

    private func send() {
        guard hostedEmailAddressLooksValid(address), !tips.isWorking else {
            return
        }
        Task {
            if await tips.optIn(address: address) {
                onSent()
            }
        }
    }
}

/// The main screen's one-time card after sign-in, during the trial: the same opt-in; "Şimdi değil" closes it for good on this iPhone.
struct PhoneEmailTipsCard: View {
    let tips: HostedEmailTips
    let account: HostedAccount
    @State private var address: String = ""

    var body: some View {
        if tips.isPromptVisible(accountState: account.state) {
            // The notice cards' look (`NoticeCard`), with the form below the text: the card's side column is too narrow
            // for a field.
            VStack(alignment: .leading, spacing: 10) {
                Text("Denemen bitmeden hatırlatalım mı?")
                    .appFont(size: 15, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: String(localized: "İstersen birkaç kısa ipucu ve denemen bitmeden bir hatırlatma e-postayla gönderelim. Onay bağlantısına tıklamadan hiçbir şey göndermeyiz.") + " " + hostedEmailPrivacyText())
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("E-posta adresin", text: $address)
                    .appFont(size: 15, weight: .regular)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let message = tips.errorMessage {
                    NoticeText(message as String, severity: .error)
                        .appFont(size: 13, weight: .regular)
                }
                HStack(spacing: 20) {
                    Button("Şimdi değil") { tips.dismissPrompt() }
                    Button("Onay bağlantısı gönder") { send() }
                        .fontWeight(.semibold)
                        .disabled(tips.isWorking || !hostedEmailAddressLooksValid(address))
                }
                .appFont(size: 14, weight: .regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        }
    }

    private func send() {
        guard hostedEmailAddressLooksValid(address), !tips.isWorking else {
            return
        }
        Task {
            if await tips.optIn(address: address) {
                // Done here: Settings › Account shows the pending address from now on.
                tips.dismissPrompt()
            }
        }
    }
}
