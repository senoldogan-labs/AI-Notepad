import AINotepadCore
import AINotepadUI
import SwiftUI

/// Çökme raporlarının gideceği sunucu: abonelik sunucusu, rapor hesaba bağlanır (Mac'teki Gistsmith gibi; sunucu
/// jetonsuz raporu kabul etmez, giriş yapılmamışsa `HostedClientError.notSignedIn`).
@MainActor
private func phoneReportDestination() async throws -> ReportDestination {
    try await hostedReportDestination()
}

/// Ayarlar'ın en üstünde: önceki açılışta uygulama çöktüyse bir kez sorar. "Gönder" (kullanıcının açık onayı) saklanan
/// raporu geliştiricinin sunucusuna yollar; hiçbir şey kendiliğinden gönderilmez.
struct CrashReportNotice: View {
    let center: CrashReportCenter

    var body: some View {
        if let report = center.reportToAnnounce {
            let state: CrashReportSendState? = center.sendStates[report.id]
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(appName) beklenmedik şekilde kapandı — raporu gönder?", systemImage: "exclamationmark.bubble")
                        .appFont(size: 15, weight: .medium)
                    Text("Raporda sürüm, sistem ve hatanın yeri var; toplantı içeriği ve anahtarlar yok. \"Gönder\"e basınca geliştiricinin sunucusuna gider.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    if case .failed(let message) = state {
                        Text(verbatim: message)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(NoticeSeverity.attention.tint)
                    }
                }
                .padding(.vertical, 4)
                if state == .sending {
                    ProgressView()
                } else {
                    Button("Gönder") {
                        Task { await center.send(report: report, destination: phoneReportDestination) }
                    }
                }
                Button("Kapat") { center.markSeen(id: report.id) }
                    .disabled(state == .sending)
            }
        }
    }
}

/// "Uygulama" bölümündeki satır: saklanan çökme ve donma raporlarının listesi.
struct CrashReportsLink: View {
    let center: CrashReportCenter

    var body: some View {
        NavigationLink {
            CrashReportsList(center: center)
        } label: {
            LabeledContent {
                Text(verbatim: "\(center.reports.count)")
            } label: {
                PhoneSettingLabel(icon: "ladybug", title: Text("Çökme raporlarını göster"))
            }
        }
    }
}

/// Saklanan raporlar: her biri geliştiricinin sunucusuna gönderilebilir, kaydırarak silinir.
private struct CrashReportsList: View {
    let center: CrashReportCenter

    var body: some View {
        List {
            Section {
                if center.reports.isEmpty {
                    Text("Kayıtlı çökme raporu yok.")
                        .foregroundStyle(Theme.muted)
                }
                ForEach(center.reports) { (report: CrashReport) in
                    let diagnostic: CrashDiagnostic = report.primaryDiagnostic
                    let state: CrashReportSendState? = center.sendStates[report.id]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(crashReportHeadline(diagnostic: diagnostic))
                            .appFont(size: 15, weight: .medium)
                        Text(verbatim: "\(report.receivedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))) · \(diagnostic.appVersion) · \(diagnostic.osVersion)")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                        switch state {
                        case .sending:
                            ProgressView()
                        case .sent:
                            Label("Gönderildi", systemImage: "checkmark")
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        case .failed(let message):
                            Text(verbatim: message)
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(NoticeSeverity.attention.tint)
                            sendButton(report: report)
                        case .none:
                            sendButton(report: report)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        Button("Sil", role: .destructive) { center.delete(id: report.id) }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Raporlar bu iPhone'da kalır; \"Gönder\" toplantı içeriği olmadan geliştiriciye yollar.")
                    if let problem = center.problem {
                        Text(problem).foregroundStyle(NoticeSeverity.attention.tint)
                    }
                    if !center.unreadableFiles.isEmpty {
                        Button("Okunamayanları sil", role: .destructive) { center.deleteUnreadable() }
                    }
                }
            }
        }
        .navigationTitle("Çökme raporları")
    }

    private func sendButton(report: CrashReport) -> some View {
        Button("Gönder") {
            Task { await center.send(report: report, destination: phoneReportDestination) }
        }
        .buttonStyle(.borderless)
    }
}
