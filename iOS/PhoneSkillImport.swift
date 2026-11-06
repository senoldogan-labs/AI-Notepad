import AINotepadCore
import AINotepadUI
import SwiftUI
import UniformTypeIdentifiers

/// Ayarlar › Beceriler (Mac'teki "SKILL.md içe aktar"): Claude ve diğer yapay zekâ araçları için yazılmış beceriler
/// (`SKILL.md`) Dosyalar'dan seçilir ve Sor'da "/" ile tarif olarak çalışır. Sonuç (eklenenler, okunamayanlar) satırın
/// altında görünür.
struct PhoneSkillImportSection: View {
    let ask: PhoneAsk
    @State private var isPicking: Bool = false
    @State private var status: String?

    var body: some View {
        Section {
            Button {
                isPicking = true
            } label: {
                PhoneSettingLabel(icon: "square.and.arrow.down", title: Text("SKILL.md içe aktar"))
            }
            if let status, !status.isEmpty {
                Text(verbatim: status)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = ask.recipeError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Beceriler (Agent Skills)")
        } footer: {
            Text("Seçtiğin beceriler Sor'da \"/\" ile tarif olarak çalışır (ör. haftalık özet, takip e-postası).")
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: skillContentTypes, allowsMultipleSelection: true) { (result: Result<[URL], any Error>) in
            switch result {
            case .success(let files):
                status = skillImportSummary(result: ask.importSkills(files: files))
            case .failure(let error):
                status = String(localized: "Dosyalar açılamadı: \(userFacingMessage(error: error))")
            }
        }
    }
}

/// Seçicide gösterilen dosyalar: Markdown (`.md`) ve düz metin.
private let skillContentTypes: [UTType] = [UTType("net.daringfireball.markdown"), UTType.plainText].compactMap { $0 }
