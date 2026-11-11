import AINotepadCore
import AINotepadUI
import SwiftUI
import os

private let phoneFeedbackLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Feedback")

/// Formun gönderim durumu.
private enum PhoneFeedbackState: Equatable {
    case editing
    case sending
    case sent
    /// Gönderilemedi; kullanıcıya gösterilen neden (form açık kalır, yeniden denenebilir).
    case failed(message: String)
}

/// Ayarlar › Geri bildirim gönder (Mac'teki formun iPhone karşılığı): mesaj (zorunlu), yanıt e-postası (isteğe bağlı) ve
/// gönderilecek haliyle sürüm ve sistem bilgisi, isteğe bağlı olarak Tanılama'daki bilgi (Mac'teki "Tanılama bilgisini
/// ekle"). Gönderim kullanıcının "Gönder"iyle olur; mesaj hesabın sunucusuna gider ve hesapla ilişkilendirilir
/// (`hostedReportDestination`). Toplantı içeriği gönderilmez.
struct PhoneFeedbackForm: View {
    /// Tanılama bilgisi bunlardan okunur (bkz. `makePhoneDiagnosticsText`).
    let account: HostedAccount
    let store: PhoneStore
    @State private var message: String = ""
    @State private var email: String = ""
    @State private var includeDiagnostics: Bool = true
    /// Ayarlar › Tanılama'daki bilgi mesajın sonuna eklenir (Mac'teki gibi varsayılan kapalı).
    @State private var includeFullDiagnostics: Bool = false
    /// "gistsmith.com'da ön adımla alıntılanabilir" (baştan kapalı; Mac'teki gibi).
    @State private var allowsQuote: Bool = false
    @State private var quoteFirstName: String = ""
    @State private var state: PhoneFeedbackState = .editing
    @FocusState private var messageFocused: Bool
    private let diagnostics: ReportDiagnostics = currentReportDiagnostics(bundle: .main, platformName: "iOS")

    var body: some View {
        let length: Int = reportMessageLength(text: message.trimmingCharacters(in: .whitespacesAndNewlines))
        let isSending: Bool = state == .sending
        PhoneGroupedList {
            if state == .sent {
                Section {
                    Label("Teşekkürler, geri bildirimin gönderildi.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ink)
                }
            } else {
                Section {
                    TextEditor(text: $message)
                        .appFont(size: 16, weight: .regular)
                        .focused($messageFocused)
                        .frame(minHeight: 160)
                } header: {
                    PhoneSecondaryText {
                        HStack {
                            Text("Mesaj")
                            Spacer()
                            Text(verbatim: "\(length) / \(reportMessageLimit)")
                                .monospacedDigit()
                                .foregroundStyle(length > reportMessageLimit ? NoticeSeverity.error.tint : Theme.muted)
                        }
                    }
                } footer: {
                    PhoneSecondaryText {
                        Text("Hata, öneri ya da soru: doğrudan Gistsmith'in geliştiricisine yaz.")
                    }
                }
                Section {
                    TextField("Yanıt için e-posta (isteğe bağlı)", text: $email, prompt: Text("ad@ornek.com").foregroundStyle(Theme.muted))
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    PhoneSecondaryText {
                        Text("Yanıt için e-posta (isteğe bağlı)")
                    }
                }
                Section {
                    Toggle("Sürüm ve sistem bilgisini ekle", isOn: $includeDiagnostics)
                    if includeDiagnostics {
                        LabeledContent("Sürüm", value: diagnostics.appVersion)
                        LabeledContent("Sistem", value: diagnostics.os)
                    }
                    Toggle(isOn: $includeFullDiagnostics) {
                        Text("Tanılama bilgisini ekle")
                        Text("Hesap durumu, izinler, bağlantı ve son hatalar; ses, metin, not ve anahtar eklenmez.")
                    }
                } header: {
                    PhoneSecondaryText {
                        Text("Gönderilenler")
                    }
                } footer: {
                    PhoneSecondaryText {
                        Text("Mesajın, varsa e-postan ve işaretli bilgiler hesabınla birlikte gider; toplantı içeriği gitmez.")
                    }
                }
                Section {
                    Toggle("Bunu gistsmith.com'da ön adımla alıntılayabilirsiniz", isOn: $allowsQuote)
                    if allowsQuote {
                        TextField("Ön adın", text: $quoteFirstName, prompt: Text("Ön adın").foregroundStyle(Theme.muted))
                            .textContentType(.givenName)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    PhoneSecondaryText {
                        Text("İsteğe bağlı. Hiçbir şey kendiliğinden yayımlanmaz: yalnızca mesajın ve ön adın gösterilebilir; e-postan ve hesabın asla.")
                    }
                }
                if case .failed(let reason) = state {
                    Section {
                        NoticeText(reason as String, severity: .error)
                    }
                }
            }
        }
        .disabled(isSending)
        .navigationTitle("Geri bildirim")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state != .sent {
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Gönder", action: send)
                            .disabled(length == 0 || length > reportMessageLimit || (allowsQuote && quoteFirstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
            }
        }
        .onAppear { messageFocused = true }
    }

    private func send() {
        let report: ReportRequest
        do {
            report = try feedbackReport(message: message, email: email, diagnostics: includeDiagnostics ? diagnostics : nil, quoteFirstName: allowsQuote ? quoteFirstName : nil)
        } catch {
            state = .failed(message: userFacingMessage(error: error))
            return
        }
        state = .sending
        Task {
            do {
                let final: ReportRequest = includeFullDiagnostics
                    ? try appendingDiagnostics(report: report, diagnosticsText: await makePhoneDiagnosticsText(account: account, store: store), limit: reportMessageLimit)
                    : report
                try await submitReport(report: final, destination: try await hostedReportDestination())
                state = .sent
            } catch {
                phoneFeedbackLogger.error("Geri bildirim gönderilemedi, hata: \(String(describing: error), privacy: .private)")
                state = .failed(message: userFacingMessage(error: error))
            }
        }
    }
}
