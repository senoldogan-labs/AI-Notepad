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
/// gönderilecek haliyle sürüm ve sistem bilgisi. Gönderim kullanıcının "Gönder"iyle olur; mesaj hesabın sunucusuna
/// gider ve hesapla ilişkilendirilir (`hostedReportDestination`). Toplantı içeriği gönderilmez.
struct PhoneFeedbackForm: View {
    @State private var message: String = ""
    @State private var email: String = ""
    @State private var includeDiagnostics: Bool = true
    @State private var state: PhoneFeedbackState = .editing
    @FocusState private var messageFocused: Bool
    private let diagnostics: ReportDiagnostics = currentReportDiagnostics(bundle: .main, platformName: "iOS")

    var body: some View {
        let length: Int = reportMessageLength(text: message.trimmingCharacters(in: .whitespacesAndNewlines))
        let isSending: Bool = state == .sending
        List {
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
                    HStack {
                        Text("Mesaj")
                        Spacer()
                        Text(verbatim: "\(length) / \(reportMessageLimit)")
                            .monospacedDigit()
                            .foregroundStyle(length > reportMessageLimit ? NoticeSeverity.error.tint : Theme.muted)
                    }
                } footer: {
                    Text("Hata, öneri ya da soru: doğrudan Gistsmith'in geliştiricisine yaz.")
                }
                Section {
                    TextField("Yanıt için e-posta (isteğe bağlı)", text: $email, prompt: Text(verbatim: "ad@ornek.com").foregroundStyle(Theme.muted))
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Yanıt için e-posta (isteğe bağlı)")
                }
                Section {
                    Toggle("Sürüm ve sistem bilgisini ekle", isOn: $includeDiagnostics)
                    if includeDiagnostics {
                        LabeledContent("Sürüm", value: diagnostics.appVersion)
                        LabeledContent("Sistem", value: diagnostics.os)
                    }
                } footer: {
                    Text("Mesajın, yazdıysan e-postan ve işaretliyse sürüm bilgisi Gistsmith'in geliştiricisinin sunucusuna gider ve hesabınla ilişkilendirilir. Toplantı içeriği gönderilmez.")
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
                            .disabled(length == 0 || length > reportMessageLimit)
                    }
                }
            }
        }
        .onAppear { messageFocused = true }
    }

    private func send() {
        let report: ReportRequest
        do {
            report = try feedbackReport(message: message, email: email, diagnostics: includeDiagnostics ? diagnostics : nil)
        } catch {
            state = .failed(message: userFacingMessage(error: error))
            return
        }
        state = .sending
        Task {
            do {
                try await submitReport(report: report, destination: try await hostedReportDestination())
                state = .sent
            } catch {
                phoneFeedbackLogger.error("Geri bildirim gönderilemedi, hata: \(String(describing: error), privacy: .private)")
                state = .failed(message: userFacingMessage(error: error))
            }
        }
    }
}
