import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kayıt başında canlı panelin üstünde: bu toplantıyla ilgili önceki toplantılardan açık görevler (en çok 5), her biri
/// kaynak toplantının başlığıyla. Yalnız hatırlatmadır (dokunmak görevi işaretlemez); "Tümünü gör" brifingi açar,
/// kapatılınca bu kayıt boyunca görünmez.
struct RelatedTasksStrip: View {
    let tasks: [RelatedOpenTask]
    let onShowAll: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Açık görevler (önceki toplantılardan)")
                    .appFont(size: 12.5, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Tümünü gör") { onShowAll() }
                    .controlSize(.small)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 10, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(Text("Kapat"))
            }
            ForEach(tasks.prefix(5)) { (item: RelatedOpenTask) in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.task.description)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(verbatim: "\(item.task.owner) · \(item.meetingTitle)")
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
                .accessibilityElement(children: .combine)
            }
            if tasks.count > 5 {
                Text("+\(tasks.count - 5) görev daha")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
