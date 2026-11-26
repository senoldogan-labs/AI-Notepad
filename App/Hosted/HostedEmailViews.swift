import AINotepadCore
import AINotepadUI
import SwiftUI

/// Settings › Account (Mac): the switch, the address field while opting in, and the pending or confirmed address. Shown
/// only while the server offers the opt-in.
struct HostedEmailTipsRow: View {
    let tips: HostedEmailTips
    @State private var isEditing: Bool = false
    @State private var address: String = ""

    var body: some View {
        if let state = tips.state, state.available || state.status != .off {
            SettingsRow(icon: "envelope", title: Text("E-posta ipuçları")) {
                Text(verbatim: hostedEmailStatusText(state: state))
                if isEditing || (state.status == .off && !address.isEmpty) {
                    Text(verbatim: hostedEmailPrivacyText())
                        .foregroundStyle(Theme.muted)
                    Link("Gizlilik politikası", destination: hostedEmailPrivacyURL)
                        .appFont(size: 12, weight: .medium)
                }
                if isEditing {
                    HStack(spacing: 8) {
                        TextField("E-posta adresin", text: $address)
                            .settingsField(width: 240)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .onSubmit { send() }
                        Button("Onay bağlantısı gönder") { send() }
                            .disabled(tips.isWorking || !hostedEmailAddressLooksValid(address))
                        Button("Vazgeç") {
                            isEditing = false
                            address = ""
                        }
                    }
                }
                if let message = tips.errorMessage {
                    NoticeText(message as String, severity: .error)
                }
            } control: {
                HStack(spacing: 8) {
                    if state.status != .off, !isEditing {
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
                    .settingsToggle()
                    .disabled(tips.isWorking)
                }
            }
        }
    }

    private func send() {
        guard hostedEmailAddressLooksValid(address), !tips.isWorking else {
            return
        }
        Task {
            if await tips.optIn(address: address) {
                isEditing = false
                address = ""
            }
        }
    }
}

/// The one-time card in the main window after sign-in (not on the sign-in gate): the same opt-in as Settings › Account,
/// closed for good with "Şimdi değil".
struct HostedEmailTipsBanner: View {
    let tips: HostedEmailTips
    @State private var address: String = ""

    var body: some View {
        NoticeBar(
            severity: .info,
            title: Text("Denemen bitmeden hatırlatalım mı?"),
            detail: Text(verbatim: String(localized: "İstersen birkaç kısa ipucu ve denemen bitmeden bir hatırlatma e-postayla gönderelim. Onay bağlantısına tıklamadan hiçbir şey göndermeyiz.") + " " + hostedEmailPrivacyText()),
            onDismiss: { tips.dismissPrompt() }
        ) {
            TextField("E-posta adresin", text: $address)
                .settingsField(width: 220)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .onSubmit { send() }
            Button("Onay bağlantısı gönder") { send() }
                .buttonStyle(.pill)
                .disabled(tips.isWorking || !hostedEmailAddressLooksValid(address))
            Button("Şimdi değil") { tips.dismissPrompt() }
                .buttonStyle(.pill)
        }
        if let message = tips.errorMessage {
            NoticeText(message as String, severity: .error)
                .padding(.horizontal, 16)
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
