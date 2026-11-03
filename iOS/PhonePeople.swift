import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kişiler (Mac'teki Kişiler sayfası): toplantılarda konuşmacıya adı verilenler ve elle eklenenler; arama ve "Kişi ekle".
/// Dokununca kişinin sayfası. Defter Mac'tekiyle aynı biçimde (`People.json`) hesabın klasöründe saklanır; elle eklenen
/// adlar konuşma tanımaya da verilir (bkz. `phoneRecognitionKeyterms`).
struct PhonePeopleList: View {
    let store: PhoneStore
    let router: PhoneRouter
    @State private var query: String = ""
    @State private var isAdding: Bool = false

    var body: some View {
        let people: [PersonSummary] = peopleDirectory(records: store.meetings, voices: [], book: store.peopleBook, userName: phoneUserName())
        let trimmed: String = query.trimmingCharacters(in: .whitespaces)
        let shown: [PersonSummary] = trimmed.isEmpty ? people : people.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.role.localizedCaseInsensitiveContains(trimmed)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                PhoneErrorList(messages: [store.peopleBookError].compactMap { $0 })
                ForEach(shown) { (person: PersonSummary) in
                    NavigationLink {
                        PhonePersonPage(store: store, router: router, personID: person.id)
                    } label: {
                        PhonePersonRow(person: person)
                    }
                    .buttonStyle(PressableCardStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if people.isEmpty {
                PhoneEmptyScene(
                    symbol: "person.2.fill", palette: .ocean, title: "Henüz kimse yok",
                    message: "Transkriptte bir konuşmacıya ad verince kişi burada görünür; toplantıları, konuşma payı ve görevleriyle."
                ) {
                    Button("Kişi ekle", systemImage: "person.badge.plus") { isAdding = true }
                        .buttonStyle(.accentPill)
                        .controlSize(.large)
                }
            } else if shown.isEmpty {
                PhoneEmptyState(symbol: "magnifyingglass", title: "Eşleşen kişi yok", message: "Başka bir kelimeyle ara.") {
                    EmptyView()
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Kişiler")
        .searchable(text: $query, prompt: "Kişi ara")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Kişi ekle", systemImage: "person.badge.plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) {
            PhonePersonForm(title: "Kişi ekle", initialName: "", lockedName: nil, initialRole: "", initialEmail: "") { (name: String, role: String, email: String) -> Void in
                store.savePerson(name: name, role: role, email: email)
            }
        }
    }
}

/// Listedeki kişi: rozet, ad ve ünvan (yoksa toplantı sayısı).
private struct PhonePersonRow: View {
    let person: PersonSummary

    var body: some View {
        HStack(spacing: 12) {
            PersonAvatar(name: person.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Group {
                    if !person.role.isEmpty {
                        Text(person.role)
                    } else if person.meetings.isEmpty {
                        Text("Henüz toplantı yok")
                    } else {
                        Text("\(person.meetings.count) toplantı")
                    }
                }
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardSurface(cornerRadius: 14)
        .contentShape(Rectangle())
    }
}

/// Kişinin sayfası: rozet, ad, ünvan, e-posta; özet sayılar, toplantıları (dokununca toplantı açılır) ve görevleri.
/// Düzenle ve Kaldır sağ üstte; kaldırma sayfanın içinde iki adımla onaylanır (ayrı uyarı penceresi yok).
private struct PhonePersonPage: View {
    let store: PhoneStore
    let router: PhoneRouter
    /// Kişinin kimliği (küçük harfli ad); kişi kaldırılınca ya da adı değişince sayfa bunu bulamaz.
    let personID: String
    @State private var isEditing: Bool = false
    @State private var confirmRemove: Bool = false
    /// Adı değişen kişinin yeni kimliği (elle eklenen, toplantısız kişi).
    @State private var renamedID: String?
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        let people: [PersonSummary] = peopleDirectory(records: store.meetings, voices: [], book: store.peopleBook, userName: phoneUserName())
        if let person = people.first(where: { $0.id == (renamedID ?? personID) }) {
            content(person: person)
        } else {
            PhoneEmptyState(symbol: "person.crop.circle.badge.questionmark", title: "Kişi bulunamadı", message: "Bu kişi kaldırılmış olabilir.") {
                EmptyView()
            }
            .background(Theme.background)
        }
    }

    private func content(person: PersonSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PhoneErrorList(messages: [store.peopleBookError].compactMap { $0 })
                HStack(alignment: .top, spacing: 14) {
                    PersonAvatar(name: person.name, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).appFont(size: 26, weight: .regular).tracking(-0.4)
                        if !person.role.isEmpty {
                            Text(person.role).appFont(size: 14, weight: .regular)
                        }
                        if !person.email.isEmpty, let url = URL(string: "mailto:\(person.email)") {
                            Link(destination: url) {
                                Label(person.email, systemImage: "envelope").lineLimit(1)
                            }
                            .appFont(size: 13, weight: .regular)
                        }
                    }
                }
                if confirmRemove {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Kişiler'den kaldırılsın mı? Toplantılardaki adı kalır.", systemImage: "person.crop.circle.badge.minus")
                            .appFont(size: 14, weight: .medium)
                        HStack(spacing: 10) {
                            Button("Kaldır", role: .destructive) {
                                store.removePerson(name: person.name)
                                if store.peopleBookError == nil {
                                    dismiss()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            Button("Vazgeç") { confirmRemove = false }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(cornerRadius: 14)
                    .transition(.opacity)
                }
                HStack(spacing: 10) {
                    stat(value: "\(person.meetings.count)", label: "toplantı")
                    // Konuşması olan kişide en az 1 dk; hiç konuşmayan (elle eklenen) kişide 0.
                    stat(value: String(localized: "\(person.totalSeconds > 0 ? max(1, Int((person.totalSeconds / 60).rounded())) : 0) dk"), label: "konuşma")
                    stat(value: "\(person.tasks.count)", label: "görev")
                }
                if person.meetings.isEmpty {
                    QuietEmptyCard(
                        symbol: "calendar.badge.clock", title: "Henüz toplantı yok",
                        message: "Bir toplantının transkriptinde konuşmacıya bu adı verince toplantıları burada görünür."
                    )
                } else {
                    meetings(person: person)
                }
                if !person.tasks.isEmpty {
                    tasks(person: person)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .animation(.smooth(duration: 0.2), value: confirmRemove)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Düzenle", systemImage: "pencil") { isEditing = true }
                    Button("Kaldır", systemImage: "trash", role: .destructive) { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Diğer")
            }
        }
        .sheet(isPresented: $isEditing) {
            // Toplantılarda adı geçen kişinin adı orada verildiği için değişmez (değişirse kişi ikiye bölünürdü); yalnızca
            // toplantısız, elle eklenen kişinin adı değişir.
            let canRename: Bool = person.isSaved && person.meetings.isEmpty
            PhonePersonForm(
                title: "Kişiyi düzenle", initialName: person.name, lockedName: canRename ? nil : person.name, initialRole: person.role,
                initialEmail: person.email
            ) { (name: String, role: String, email: String) -> Void in
                if canRename {
                    store.renamePerson(oldName: person.name, name: name, role: role, email: email)
                    // Yazılamadıysa kişi eski adıyla kalır (neden sayfada görünür).
                    if store.peopleBookError == nil {
                        renamedID = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                } else {
                    store.savePerson(name: person.name, role: role, email: email)
                }
            }
        }
    }

    private func meetings(person: PersonSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("TOPLANTILARI")
            VStack(spacing: 0) {
                ForEach(Array(person.meetings.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonMeeting)) in
                    if item.offset > 0 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    Button {
                        router.open(meetingID: item.element.meetingID)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.title)
                                    .appFont(size: 15, weight: .medium)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text(item.element.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                                    .appFont(size: 12, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 8)
                            Text("Konuşma payı \(item.element.fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))")
                                .appFont(size: 12, weight: .medium)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                            Image(systemName: "chevron.right")
                                .appFont(size: 11, weight: .semibold)
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .cardSurface(cornerRadius: 14)
        }
    }

    private func tasks(person: PersonSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("GÖREVLERİ")
            ForEach(Array(person.tasks.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonTask)) in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.element.task.description)
                        .appFont(size: 15, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(([item.element.task.dueDate].compactMap { $0 } + [item.element.meetingTitle]).joined(separator: " · "))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(cornerRadius: 12)
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .appFont(size: 12, weight: .semibold)
            .tracking(DesignTokens.labelTracking)
            .foregroundStyle(Theme.muted)
    }

    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).appFont(size: 22, weight: .regular).monospacedDigit()
            Text(label).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12)
    }
}

/// Kişi ekleme/düzenleme sayfası: ad (zorunlu), ünvan ya da kurum, e-posta. `lockedName` verilirse ad değiştirilemez
/// (toplantılarda verilmiş ad).
private struct PhonePersonForm: View {
    let title: LocalizedStringKey
    let lockedName: String?
    let onSave: @MainActor (String, String, String) -> Void
    @State private var name: String
    @State private var role: String
    @State private var email: String
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss: DismissAction

    init(title: LocalizedStringKey, initialName: String, lockedName: String?, initialRole: String, initialEmail: String, onSave: @escaping @MainActor (String, String, String) -> Void) {
        self.title = title
        self.lockedName = lockedName
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _role = State(initialValue: initialRole)
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let lockedName {
                        LabeledContent("Ad", value: lockedName)
                    } else {
                        TextField("Ad", text: $name, prompt: Text("Örn. Aino Virtanen"))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($nameFocused)
                    }
                    TextField("Ünvan ya da kurum", text: $role, prompt: Text("Örn. Ürün müdürü, Acme"))
                    TextField("E-posta", text: $email, prompt: Text("ad@ornek.com"))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if lockedName != nil {
                        Text("Bu ad toplantılarda verildi; toplantının Transkript sekmesinden değiştir.")
                    } else {
                        Text("Ad konuşma tanımaya verilir; kişinin toplantıları ve görevleri burada toplanır.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        onSave(name, role, email)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { nameFocused = lockedName == nil }
        }
    }
}
