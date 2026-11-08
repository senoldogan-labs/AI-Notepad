import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kişiler (Mac'teki Kişiler sayfası): toplantılarda konuşmacıya adı verilenler ve elle eklenenler; arama ve "Kişi ekle".
/// Dokununca kişinin sayfası açılır pencerede. Defter Mac'tekiyle aynı biçimde (`People.json`) hesabın klasöründe saklanır; elle eklenen
/// adlar konuşma tanımaya da verilir (bkz. `phoneRecognitionKeyterms`). Şirketler sekmesi kişileri e-posta alan adına
/// göre gruplar (bkz. `companies`); şirketin sayfası kişilerini ve toplantılarını listeler.
struct PhonePeopleList: View {
    let store: PhoneStore
    let router: PhoneRouter
    @State private var query: String = ""
    @State private var isAdding: Bool = false
    /// Penceresi açık kişi (kimliği).
    @State private var openedID: String?
    @State private var tab: PhonePeopleTab = .people
    /// Penceresi açık şirket (alan adı).
    @State private var openedCompanyID: String?

    var body: some View {
        let people: [PersonSummary] = store.peopleDirectory()
        let trimmed: String = query.trimmingCharacters(in: .whitespaces)
        let shown: [PersonSummary] = trimmed.isEmpty ? people : people.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.role.localizedCaseInsensitiveContains(trimmed)
        }
        let allCompanies: [CompanySummary] = companies(people: people, ownEmail: HostedAccount.shared.signedInIdentity?.email)
        let shownCompanies: [CompanySummary] = trimmed.isEmpty ? allCompanies : allCompanies.filter { (company: CompanySummary) -> Bool in
            company.name.localizedCaseInsensitiveContains(trimmed) || company.domain.localizedCaseInsensitiveContains(trimmed)
                || company.people.contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PhoneErrorList(messages: [store.peopleBookError].compactMap { $0 })
                if !people.isEmpty {
                    UnderlineTabs(selection: $tab, options: [
                        (value: PhonePeopleTab.people, title: "Kişiler"), (value: PhonePeopleTab.companies, title: "Şirketler"),
                    ])
                    .padding(.bottom, 4)
                }
                switch tab {
                case .people:
                    // Mac'teki tablo gibi tek yüzeyde ince çizgili satırlar; dokununca (göz) kişinin sayfası pencerede açılır.
                    if !shown.isEmpty {
                        HairlineList(items: shown, tint: nil) { (person: PersonSummary) in
                            Button {
                                openedID = person.id
                            } label: {
                                PhonePersonRow(person: person)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .companies:
                    if allCompanies.isEmpty, !people.isEmpty {
                        QuietEmptyCard(
                            symbol: "building.2", title: "Henüz şirket yok",
                            message: "Şirketler kişilerin e-posta adreslerinden gelir; bir kişiye iş e-postası ekleyince şirketi burada görünür."
                        )
                    } else if !shownCompanies.isEmpty {
                        HairlineList(items: shownCompanies, tint: nil) { (company: CompanySummary) in
                            Button {
                                openedCompanyID = company.id
                            } label: {
                                CompanyListRow(company: company)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if people.isEmpty {
                // Defter okunamadıysa sahne üstteki hatanın üstüne binmez (eklemek de aynı nedenle yapılamaz).
                if store.peopleBookError == nil {
                    PhoneEmptyScene(
                        symbol: "person.2.fill", palette: .ocean, title: "Henüz kimse yok",
                        message: "Transkriptte bir konuşmacıya ad verince kişi burada görünür; toplantıları, konuşma payı ve görevleriyle."
                    ) {
                        Button("Kişi ekle", systemImage: "person.badge.plus") { isAdding = true }
                            .buttonStyle(.accentPill)
                            .controlSize(.large)
                    }
                }
            } else if tab == .people, shown.isEmpty {
                PhoneEmptyState(symbol: "magnifyingglass", title: "Eşleşen kişi yok", message: "Başka bir kelimeyle ara.") {
                    EmptyView()
                }
            } else if tab == .companies, !allCompanies.isEmpty, shownCompanies.isEmpty {
                PhoneEmptyState(symbol: "magnifyingglass", title: "Eşleşen şirket yok", message: "Başka bir kelimeyle ara.") {
                    EmptyView()
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Kişiler")
        .searchable(text: $query, prompt: tab == .people ? "Kişi ara" : "Şirket ara")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Kişi ekle", systemImage: "person.badge.plus") { isAdding = true }
            }
        }
        .sheet(isPresented: Binding<Bool>(
            get: { openedID != nil },
            set: { (shown: Bool) -> Void in
                if !shown {
                    openedID = nil
                }
            }
        )) {
            if let openedID {
                NavigationStack {
                    PhonePersonPage(store: store, router: router, personID: openedID)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Kapat") { self.openedID = nil }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: Binding<Bool>(
            get: { openedCompanyID.map { (id: String) -> Bool in allCompanies.contains { $0.id == id } } ?? false },
            set: { (shown: Bool) -> Void in
                if !shown {
                    openedCompanyID = nil
                }
            }
        )) {
            if let company = allCompanies.first(where: { $0.id == openedCompanyID }) {
                NavigationStack {
                    PhoneCompanyPage(store: store, router: router, company: company)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Kapat") { openedCompanyID = nil }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isAdding) {
            PhonePersonForm(title: "Kişi ekle", initialName: "", lockedName: nil, initialRole: "", initialEmail: "") { (name: String, role: String, email: String) -> Void in
                store.savePerson(name: name, role: role, email: email)
            }
        }
    }
}

/// Kişiler sayfasının sekmeleri.
private enum PhonePeopleTab: Hashable {
    case people
    case companies
}

/// Şirketin sayfası: harf karosu, ad, alan adı; özet sayılar, kişileri (dokununca kişinin sayfası aynı pencerede açılır)
/// ve toplantıları (dokununca pencere kapanır, toplantı açılır).
private struct PhoneCompanyPage: View {
    let store: PhoneStore
    let router: PhoneRouter
    let company: CompanySummary
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    CompanyTile(name: company.name, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: company.name).appFont(size: 26, weight: .regular).tracking(-0.4)
                        Label(company.domain, systemImage: "globe")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                        if company.isOwn {
                            OwnCompanyBadge()
                        }
                    }
                }
                HStack(spacing: 10) {
                    stat(value: "\(company.people.count)", label: "kişi")
                    stat(value: "\(company.meetingCount)", label: "toplantı")
                    stat(value: String(localized: "\(company.totalSeconds > 0 ? max(1, Int((company.totalSeconds / 60).rounded())) : 0) dk"), label: "konuşma")
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("KİŞİLERİ")
                    VStack(spacing: 0) {
                        ForEach(Array(company.people.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonSummary)) in
                            if item.offset > 0 {
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                            NavigationLink {
                                PhonePersonPage(store: store, router: router, personID: item.element.id)
                            } label: {
                                HStack(spacing: 12) {
                                    PersonAvatar(name: item.element.name, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.element.name)
                                            .appFont(size: 15, weight: .medium)
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Text(item.element.role.isEmpty ? item.element.email : item.element.role)
                                            .appFont(size: 12, weight: .regular)
                                            .foregroundStyle(Theme.muted)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
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
                if company.meetings.isEmpty {
                    QuietEmptyCard(
                        symbol: "calendar.badge.clock", title: "Henüz toplantı yok",
                        message: "Bir toplantının transkriptinde konuşmacıya bu şirketten birinin adını verince toplantıları burada görünür."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("TOPLANTILARI")
                        VStack(spacing: 0) {
                            ForEach(Array(company.meetings.enumerated()), id: \.offset) { (item: (offset: Int, element: CompanyMeeting)) in
                                if item.offset > 0 {
                                    Rectangle().fill(Theme.line).frame(height: 1)
                                }
                                Button {
                                    // Şirket penceresi önce kapanır: toplantı onun altında açılmasın.
                                    dismiss()
                                    router.open(meetingID: item.element.meetingID)
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.element.title)
                                                .appFont(size: 15, weight: .medium)
                                                .foregroundStyle(Theme.ink)
                                                .lineLimit(1)
                                            // Tarih ve şirketten bu toplantıda konuşanlar.
                                            Text(verbatim: item.element.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
                                                + " · " + item.element.people.formatted(.list(type: .and).locale(interfaceLocale())))
                                                .appFont(size: 12, weight: .regular)
                                                .foregroundStyle(Theme.muted)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
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
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
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
            if person.hasVoiceprint {
                Image(systemName: "waveform.badge.checkmark")
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel(Text("Sesinden tanınıyor"))
            }
            // Satırın tamamı dokunulur: iOS'un alışılmış ileri oku (göz simgesi ne yaptığını söylemiyordu).
            Image(systemName: "chevron.right")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        let people: [PersonSummary] = store.peopleDirectory()
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
                        // Mac'teki gibi sesin durumu; sesinden tanıma kapalıyken yalnız kayıtlı sesi olan kişide.
                        if person.hasVoiceprint || phoneVoiceRecognitionEnabled() {
                            Label(person.hasVoiceprint ? LocalizedStringKey("Sesinden tanınıyor") : LocalizedStringKey("Sesi henüz kayıtlı değil"), systemImage: person.hasVoiceprint ? "waveform.badge.checkmark" : "waveform")
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                if confirmRemove {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(person.hasVoiceprint ? LocalizedStringKey("Kişiler'den kaldırılsın mı? Toplantılardaki adı kalır, sesi unutulur.") : LocalizedStringKey("Kişiler'den kaldırılsın mı? Toplantılardaki adı kalır."), systemImage: "person.crop.circle.badge.minus")
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
                    // Kişinin toplantılarına sor: pencere kapanır, Sor bu kişinin kapsamıyla açılır (Mac'teki ⌘J gibi).
                    // Örnek toplantının kurgusal kişisinde yok (örnek toplantı kişi kapsamına girmez).
                    if !askScopeMeetings(scope: .person(name: person.name), records: store.meetings, now: Date(), calendar: Calendar.current).isEmpty {
                        Button("Bu kişiyle toplantılarına sor", systemImage: "sparkle") {
                            dismiss()
                            router.openAsk(context: .person(name: person.name))
                        }
                        .buttonStyle(.accentPill)
                    }
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
                        // Kişi penceresi önce kapanır: toplantı onun altında açılmasın.
                        dismiss()
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
                    // Son gün toplantı gününe göre çözülür, arayüz dilinde göreli; yanında toplantının adı.
                    HStack(spacing: 5) {
                        TaskDueText(personTask: item.element, size: 12)
                        if item.element.task.dueDate != nil {
                            Text(verbatim: "·").foregroundStyle(Theme.muted)
                        }
                        Text(verbatim: item.element.meetingTitle)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    .appFont(size: 12, weight: .regular)
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
