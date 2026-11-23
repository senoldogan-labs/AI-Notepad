import AINotepadUI
import KeyboardCore
import SwiftUI

/// Settings › Keyboard › What the keyboard learned: how many words it picked up while you type and which, and a button
/// that deletes them. The list is the file the keyboard writes to the App Group (Full Access only); it stays on this
/// iPhone.
struct PhoneKeyboardLearnedView: View {
    let host: PhoneKeyboardHost
    @State private var learned: KeyboardLearnedWords?
    @State private var isConfirmingDelete: Bool = false
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    var body: some View {
        PhoneGroupedList {
            Section {
                HStack {
                    Text("Öğrenilen kelime")
                    Spacer()
                    Text(verbatim: String(words.count))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                }
                Button("Öğrenilenleri sil", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(words.isEmpty)
            } footer: {
                PhoneSecondaryText {
                    Text("Düzelttiğin ve “yazdığım gibi kalsın” dediğin kelimeleri klavye bir sonraki sefer düzeltmez. Yalnız bu iPhone'da kalır, hiçbir yere gönderilmez. Parola ve diğer gizli alanlarda hiçbir şey öğrenilmez. Liste için Tam Erişim gerekir.")
                }
            }
            if !words.isEmpty {
                Section {
                    ForEach(words, id: \.self) { (word: String) in
                        Text(verbatim: word)
                    }
                } header: {
                    PhoneSecondaryText {
                        Text("Kelimeler")
                    }
                }
            }
        }
        .navigationTitle(Text("Klavyenin öğrendikleri"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { learned = host.learnedWords() }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            if phase == .active {
                learned = host.learnedWords()
            }
        }
        .confirmationDialog("Klavyenin öğrendiği kelimeler silinsin mi?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Öğrenilenleri sil", role: .destructive) {
                host.deleteLearnedWords()
                learned = host.learnedWords()
            }
        }
    }

    /// Newest first.
    private var words: [String] {
        (learned?.words ?? []).reversed()
    }
}
