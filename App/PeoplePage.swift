import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Kişiler: toplantılarda adı verilen konuşmacılar ve elle eklenenler, sütunları sıralanabilen bir tabloda (kişi,
/// ünvan, toplantı sayısı, konuşma süresi, son görüldüğü gün, sesinden tanınıyor mu). Satırdaki göz düğmesi, çift tık
/// ya da Return kişinin sayfasını küçük bir pencerede açar (düzenle, kaldır, toplantıları ve görevleri); sağ tık menüsü
/// aynı eylemleri sunar. Üstte arama ve "Kişi ekle". Şirketler sekmesi kişileri e-posta alan adına göre gruplar (bkz.
/// `companies`); şirketin penceresi kişilerini (dokununca kişinin sayfası aynı pencerede) ve toplantılarını listeler.
struct PeoplePage: View {
    let model: AppModel
    let router: MainWindowRouter
    @State private var selection: String?
    /// Penceresi açık kişi (kimliği; kişi kaldırılınca ya da adı değişince pencere kapanır).
    @State private var openedID: String?
    @State private var isAdding: Bool = false
    @State private var filter: String = ""
    @State private var sortOrder: [KeyPathComparator<PersonSummary>] = [KeyPathComparator(\PersonSummary.lastSeen, order: .reverse)]
    @State private var companySelection: String?
    /// Penceresi açık şirket (alan adı; şirketin son kişisi gidince pencere kapanır).
    @State private var openedCompanyID: String?
    /// Şirket penceresinde açılan kişi (kimliği); nil ise şirketin kendisi gösterilir.
    @State private var companyPersonID: String?
    @State private var companySortOrder: [KeyPathComparator<CompanySummary>] = [KeyPathComparator(\CompanySummary.lastSeenSort, order: .reverse)]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let people: [PersonSummary] = model.peopleDirectory()
        let query: String = filter.trimmingCharacters(in: .whitespaces)
        let shown: [PersonSummary] = (query.isEmpty ? people : people.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.role.localizedCaseInsensitiveContains(query)
                || $0.email.localizedCaseInsensitiveContains(query)
        }).sorted(using: sortOrder)
        let allCompanies: [CompanySummary] = companies(people: people, ownEmail: ownAccountEmail())
        let shownCompanies: [CompanySummary] = (query.isEmpty ? allCompanies : allCompanies.filter { (company: CompanySummary) -> Bool in
            company.name.localizedCaseInsensitiveContains(query) || company.domain.localizedCaseInsensitiveContains(query)
                || company.people.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }).sorted(using: companySortOrder)
        VStack(alignment: .leading, spacing: 0) {
            if people.isEmpty, model.peopleBookError == nil {
                CenteredScroll {
                    EmptyScene(
                        symbol: "person.2.fill", palette: .ocean, title: "Henüz kimse yok",
                        message: "Transkriptte bir konuşmacıya ad verince kişi burada görünür; toplantıları, konuşma payı ve görevleriyle."
                    ) {
                        Button("Kişi ekle", systemImage: "person.badge.plus") { isAdding = true }
                            .buttonStyle(.accentPill)
                            .controlSize(.large)
                    }
                }
            } else {
                header(count: people.count)
                if let error = model.peopleBookError {
                    NoticeText(error, severity: .error)
                        .appFont(size: 12, weight: .regular)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
                switch router.peopleTab {
                case .people:
                    table(shown: shown)
                        .overlay {
                            if shown.isEmpty, !people.isEmpty {
                                Text("Eşleşen kişi yok")
                                    .appFont(size: 13, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                case .companies:
                    if allCompanies.isEmpty {
                        QuietEmptyCard(
                            symbol: "building.2", title: "Henüz şirket yok",
                            message: "Şirketler kişilerin e-posta adreslerinden gelir; bir kişiye iş e-postası ekleyince şirketi burada görünür."
                        )
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    } else {
                        companyTable(shown: shownCompanies)
                            .overlay {
                                if shownCompanies.isEmpty {
                                    Text("Eşleşen şirket yok")
                                        .appFont(size: 13, weight: .regular)
                                        .foregroundStyle(Theme.muted)
                                }
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ⌘J seçili kişiyle Sor'u açar.
        .onChange(of: selection, initial: true) { (_: String?, id: String?) -> Void in
            // Yalnız Sor'un okuyabileceği toplantısı olan kişi (örnek toplantının kurgusal kişisi değil).
            router.selectedPersonName = people.first { $0.id == id && hasAskableMeetings(person: $0) }?.name
        }
        // "Kişi ekle" ayrı sayfa değil, küçük bir pencere: kullanıcı tablodan ayrılmaz.
        .sheet(isPresented: $isAdding) {
            PersonForm(title: "Kişi ekle", initialName: "", lockedName: nil, initialRole: "", initialEmail: "") { (name: String, role: String, email: String) -> Void in
                model.savePerson(name: name, role: role, email: email)
                selection = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                isAdding = false
            } onCancel: {
                isAdding = false
            }
            .frame(width: 480)
            .modifier(AppSheetChrome())
        }
        .sheet(isPresented: Binding<Bool>(
            get: { openedID.map { (id: String) -> Bool in people.contains { $0.id == id } } ?? false },
            set: { (shown: Bool) -> Void in
                if !shown {
                    openedID = nil
                }
            }
        )) {
            if let person = people.first(where: { $0.id == openedID }) {
                personSheet(person: person) { (id: String?) -> Void in openedID = id }
            }
        }
        .sheet(isPresented: Binding<Bool>(
            get: { openedCompanyID.map { (id: String) -> Bool in allCompanies.contains { $0.id == id } } ?? false },
            set: { (shown: Bool) -> Void in
                if !shown {
                    openedCompanyID = nil
                    companyPersonID = nil
                }
            }
        )) {
            if let personID = companyPersonID, let person = people.first(where: { $0.id == personID }) {
                // Şirketin kişisi aynı pencerede açılır; kapatınca şirkete dönülür.
                personSheet(person: person) { (id: String?) -> Void in companyPersonID = id }
            } else if let company = allCompanies.first(where: { $0.id == openedCompanyID }) {
                CompanyDetail(company: company, router: router) { (id: String) -> Void in
                    companyPersonID = id
                } onClose: {
                    openedCompanyID = nil
                }
                .frame(width: 640, height: 600)
                .modifier(AppSheetChrome())
            }
        }
    }

    /// Başlık satırı: ad ve kişi sayısı, arama, "Kişi ekle"; altında Kişiler | Şirketler sekmeleri.
    @ViewBuilder
    private func header(count: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Kişiler").appFont(size: 28, weight: .regular).tracking(-0.4)
                Text(verbatim: "\(count)")
                    .appFont(size: 15, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(router.peopleTab == .people ? "Kişi ara" : "Şirket ara", text: $filter).textFieldStyle(.plain)
            }
            .appFont(size: 13, weight: .regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 240)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Button("Kişi ekle", systemImage: "person.badge.plus") { isAdding = true }
                .buttonStyle(.accentPill)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 10)
        UnderlineTabs(selection: Binding<PeopleTab>(get: { router.peopleTab }, set: { router.peopleTab = $0 }), options: [
            (value: PeopleTab.people, title: "Kişiler"), (value: PeopleTab.companies, title: "Şirketler"),
        ])
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    /// Kişi tablosu: başlıklara tıklayınca sıralanır; satır seçilir, çift tık ya da Return kişiyi açar.
    private func table(shown: [PersonSummary]) -> some View {
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Kişi", value: \.name) { (person: PersonSummary) in
                HStack(spacing: 10) {
                    PersonAvatar(name: person.name, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        // Seçili satır sistemin mavisiyle boyanmaz; seçili kişinin adı vurgu renginde.
                        Text(person.name)
                            .appFont(size: 14, weight: .medium)
                            .foregroundStyle(selection == person.id ? appearance.accent.color : Theme.ink)
                            .lineLimit(1)
                        if !person.email.isEmpty {
                            Text(person.email).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 6)
                // E-postası olmayan satır da aynı yükseklikte.
                .frame(minHeight: 44, alignment: .leading)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Ünvan ya da kurum", value: \.role) { (person: PersonSummary) in
                Text(person.role.isEmpty ? "—" : person.role)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(person.role.isEmpty ? Theme.muted : Theme.ink)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Toplantılar", value: \.meetingCount) { (person: PersonSummary) in
                Text(verbatim: "\(person.meetingCount)")
                    .appFont(size: 13, weight: .regular)
                    .monospacedDigit()
            }
            .width(min: 72, ideal: 96)
            .alignment(.numeric)
            TableColumn("Konuşma", value: \.totalSeconds) { (person: PersonSummary) in
                Text(talkMinutes(person: person))
                    .appFont(size: 13, weight: .regular)
                    .monospacedDigit()
            }
            .width(min: 72, ideal: 96)
            .alignment(.numeric)
            TableColumn("Son görüldü", value: \.lastSeen) { (person: PersonSummary) in
                Group {
                    if let date = person.meetings.first?.date {
                        Text(lastSeenText(date: date, now: Date()))
                    } else {
                        Text(verbatim: "—").foregroundStyle(Theme.muted)
                    }
                }
                .appFont(size: 13, weight: .regular)
                .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
            TableColumn("") { (person: PersonSummary) in
                rowActions(person: person)
            }
            .width(120)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(PlainTableSelection())
        .contextMenu(forSelectionType: String.self) { (ids: Set<String>) in
            if let id = ids.first {
                Button("Bilgilerini göster", systemImage: "info.circle") { openedID = id }
            }
        } primaryAction: { (ids: Set<String>) -> Void in
            openedID = ids.first
        }
        .padding(.horizontal, 12)
    }

    /// Şirket tablosu: kişi tablosuyla aynı biçimde (sıralanabilir sütunlar, sistem mavisi olmadan seçim, çift tık ya da
    /// Return şirketin penceresini açar).
    private func companyTable(shown: [CompanySummary]) -> some View {
        Table(shown, selection: $companySelection, sortOrder: $companySortOrder) {
            TableColumn("Şirket", value: \.name) { (company: CompanySummary) in
                HStack(spacing: 10) {
                    CompanyTile(name: company.name, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(verbatim: company.name)
                                .appFont(size: 14, weight: .medium)
                                .foregroundStyle(companySelection == company.id ? appearance.accent.color : Theme.ink)
                                .lineLimit(1)
                            if company.isOwn {
                                OwnCompanyBadge()
                            }
                        }
                        Text(verbatim: company.domain).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                .padding(.vertical, 6)
                .frame(minHeight: 44, alignment: .leading)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Kişiler", value: \.peopleCount) { (company: CompanySummary) in
                Text(verbatim: "\(company.peopleCount)")
                    .appFont(size: 13, weight: .regular)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 84)
            .alignment(.numeric)
            TableColumn("Toplantılar", value: \.meetingCount) { (company: CompanySummary) in
                Text(verbatim: "\(company.meetingCount)")
                    .appFont(size: 13, weight: .regular)
                    .monospacedDigit()
            }
            .width(min: 72, ideal: 96)
            .alignment(.numeric)
            TableColumn("Konuşma", value: \.totalSeconds) { (company: CompanySummary) in
                Text(talkMinutes(seconds: company.totalSeconds))
                    .appFont(size: 13, weight: .regular)
                    .monospacedDigit()
            }
            .width(min: 72, ideal: 96)
            .alignment(.numeric)
            TableColumn("Son görüldü", value: \.lastSeenSort) { (company: CompanySummary) in
                Group {
                    if let date = company.lastSeen {
                        Text(lastSeenText(date: date, now: Date()))
                    } else {
                        Text(verbatim: "—").foregroundStyle(Theme.muted)
                    }
                }
                .appFont(size: 13, weight: .regular)
                .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
            TableColumn("") { (company: CompanySummary) in
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button {
                        companySelection = company.id
                        openedCompanyID = company.id
                    } label: {
                        Text("Ayrıntılar")
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                    }
                    .buttonStyle(.hoverPlain)
                    .accessibilityLabel(Text("Bilgilerini göster"))
                }
            }
            .width(96)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(PlainTableSelection())
        .contextMenu(forSelectionType: String.self) { (ids: Set<String>) in
            if let id = ids.first {
                Button("Bilgilerini göster", systemImage: "info.circle") { openedCompanyID = id }
            }
        } primaryAction: { (ids: Set<String>) -> Void in
            openedCompanyID = ids.first
        }
        .padding(.horizontal, 12)
    }

    /// Satırın sağı: sesinden tanınıyorsa dalga simgesi, "Ayrıntılar" (bilgileri pencerede açar).
    private func rowActions(person: PersonSummary) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if person.hasVoiceprint {
                Image(systemName: "waveform.badge.checkmark")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(appearance.accent.color)
                    .hoverHint("Sesinden tanınıyor", alignment: .trailing, edge: .bottom)
                    .accessibilityLabel(Text("Sesinden tanınıyor"))
            }
            // Yazılı düğme: tek başına göz simgesi ne yaptığını söylemiyordu.
            Button {
                selection = person.id
                openedID = person.id
            } label: {
                Text("Ayrıntılar")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
            }
            .buttonStyle(.hoverPlain)
            .accessibilityLabel(Text("Bilgilerini göster"))
        }
    }

    /// Kişinin Sor'un okuyabileceği toplantısı var mı (örnek toplantı kişi kapsamına girmez; bkz. `askScopeMeetings`).
    private func hasAskableMeetings(person: PersonSummary) -> Bool {
        !askScopeMeetings(scope: .person(name: person.name), records: model.meetings, now: Date(), calendar: Calendar.current).isEmpty
    }

    /// Kişinin penceresi: kişinin sayfası, sağ üstte kapat. `show` pencerede gösterilen kişiyi değiştirir (adı değişince
    /// yeni kimlik, kaldırılınca ya da kapatılınca nil).
    private func personSheet(person: PersonSummary, show: @escaping @MainActor (String?) -> Void) -> some View {
        PersonDetail(person: person, router: router, hasAskableMeetings: hasAskableMeetings(person: person)) { (name: String, role: String, email: String) -> Void in
            // Toplantılarda adı geçen kişinin adı toplantılarda verildiği için değişmez (değişirse kişi ikiye
            // bölünürdü); yalnızca toplantısız, elle eklenen kişinin adı değişir.
            if person.isSaved, person.meetings.isEmpty {
                model.renamePerson(oldName: person.name, name: name, role: role, email: email)
                let renamed: String = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                selection = renamed
                show(renamed)
            } else {
                model.savePerson(name: person.name, role: role, email: email)
            }
        } onRemove: {
            model.removePerson(name: person.name)
            show(nil)
            selection = nil
        } onClose: {
            show(nil)
        }
        .frame(width: 640, height: 600)
        .modifier(AppSheetChrome())
    }
}

/// Kişiler sayfasının sekmeleri.
enum PeopleTab: Hashable {
    case people
    case companies
}

/// Hesabın giriş e-postası (kendi şirketini işaretlemek için); geliştirici sürümünde ve kimliği bilinmeyen hesapta nil.
@MainActor
private func ownAccountEmail() -> String? {
    #if HOSTED_EDITION
    HostedAccount.shared.signedInIdentity?.email
    #else
    nil
    #endif
}

/// Tablonun seçim boyasını kapatır: macOS seçili satırı sistem vurgu rengiyle (çoğunlukla mavi) doldurur, bu da
/// uygulamanın renkleriyle çakışır. SwiftUI `Table` bunu ayarlatmadığı için arkadaki NSTableView bulunup seçim
/// vurgusu kapatılır; seçim, çift tık ve Return çalışmaya devam eder.
private struct PlainTableSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TableSelectionProbe()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TableSelectionProbe)?.applyToTable()
    }
}

/// Pencereye eklenince en yakın ata görünümün altındaki ilk NSTableView'un seçim vurgusunu kapatır.
private final class TableSelectionProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tablo bu görünümle aynı karede eklendiği için bir sonraki turda aranır.
        DispatchQueue.main.async { [weak self] in self?.applyToTable() }
    }

    func applyToTable() {
        var ancestor: NSView? = superview
        for _ in 0..<6 {
            guard let view = ancestor else { return }
            if let table = firstTable(in: view) {
                table.selectionHighlightStyle = .none
                return
            }
            ancestor = view.superview
        }
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        // SwiftUI Table bir NSOutlineView alt sınıfıdır; tek sütunlu listeler (kenar çubuğu gibi) atlanır.
        if let table = view as? NSTableView, table.numberOfColumns > 1 {
            return table
        }
        for child in view.subviews {
            if let table = firstTable(in: child) {
                return table
            }
        }
        return nil
    }
}

/// Konuşma süresi: konuşması olan kişide en az 1 dk; hiç konuşmayan (elle eklenen) kişide 0. Saf fonksiyondur.
private func talkMinutes(person: PersonSummary) -> String {
    talkMinutes(seconds: person.totalSeconds)
}

/// Konuşma süresi dakika olarak: konuşma varsa en az 1 dk, yoksa 0. Saf fonksiyondur.
private func talkMinutes(seconds: Double) -> String {
    String(localized: "\(seconds > 0 ? max(1, Int((seconds / 60).rounded())) : 0) dk")
}

/// Son görüldüğü gün: bu yıl içindeyse yılsız ("5 Kas"), değilse yıllı ("5 Kas 2025"). Saf fonksiyondur.
private func lastSeenText(date: Date, now: Date) -> String {
    let calendar: Calendar = Calendar.current
    let style: Date.FormatStyle = calendar.isDate(date, equalTo: now, toGranularity: .year)
        ? Date.FormatStyle().month(.abbreviated).day()
        : Date.FormatStyle().month(.abbreviated).day().year()
    return date.formatted(style.locale(interfaceLocale()))
}

/// Tablonun sıralama anahtarları.
extension PersonSummary {
    var meetingCount: Int { meetings.count }
    /// Son görüldüğü toplantının tarihi (toplantılar yeniden eskiye); toplantısız kişide en eski tarih.
    var lastSeen: Date { meetings.first?.date ?? .distantPast }
}

/// Şirket tablosunun sıralama anahtarları.
extension CompanySummary {
    var peopleCount: Int { people.count }
    /// Son toplantının tarihi; toplantısız şirkette en eski tarih.
    var lastSeenSort: Date { lastSeen ?? .distantPast }
}

/// Formun alanları (odak hangi alanda: çerçevesi vurgu renginde).
private enum PersonField: Hashable {
    case name
    case role
    case email
}

/// Kişi ekleme/düzenleme formu: ad (zorunlu), ünvan ya da kurum, e-posta. `lockedName` verilirse ad değiştirilemez
/// (toplantılarda verilmiş ad; değişirse kişi ikiye bölünürdü). Rozet ad yazıldıkça kişinin baş harfi ve rengiyle
/// güncellenir; ana eylem kullanıcının vurgu renginde, sağ altta.
private struct PersonForm: View {
    let title: LocalizedStringKey
    let lockedName: String?
    let onSave: @MainActor (String, String, String) -> Void
    let onCancel: @MainActor () -> Void
    @State private var name: String
    @State private var role: String
    @State private var email: String
    @FocusState private var focused: PersonField?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    init(title: LocalizedStringKey, initialName: String, lockedName: String?, initialRole: String, initialEmail: String, onSave: @escaping @MainActor (String, String, String) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.title = title
        self.lockedName = lockedName
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
        _role = State(initialValue: initialRole)
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        let trimmedName: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSave: Bool = !trimmedName.isEmpty
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                avatar(name: lockedName ?? trimmedName)
                Text(title).appFont(size: 22, weight: .semibold).tracking(-0.3)
            }
            VStack(alignment: .leading, spacing: 14) {
                if let lockedName {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ad").appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
                        Text(lockedName).appFont(size: 14, weight: .medium)
                        Text("Ad toplantılarda verildi; değiştirmek için toplantının Transkript sekmesini kullan.")
                            .appFont(size: 11, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        field(.name, label: "Ad", prompt: "Örn. Aino Virtanen", text: $name)
                        Text("Ad konuşma tanımaya verilir; bir toplantıda konuşmacıya bu adı verince toplantıları ve görevleri burada toplanır.")
                            .appFont(size: 11, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                field(.role, label: "Ünvan ya da kurum", prompt: "Örn. Ürün müdürü, Acme", text: $role)
                field(.email, label: "E-posta", prompt: "aino@ornek.fi", text: $email)
                    .textContentType(.emailAddress)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Vazgeç") { onCancel() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button("Kaydet") { onSave(name, role, email) }
                    .buttonStyle(.accentPill)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: 620, alignment: .leading)
        .onAppear { focused = lockedName == nil ? .name : .role }
    }

    /// Ad yazılmadan kişi simgesi (vurgu renginde), yazılınca kişinin rozeti.
    @ViewBuilder
    private func avatar(name: String) -> some View {
        if name.isEmpty {
            Image(systemName: "person.fill")
                .appFont(size: 22, weight: .medium)
                .foregroundStyle(appearance.accent.color)
                .frame(width: 52, height: 52)
                .background(Circle().fill(appearance.accent.color.opacity(0.15)))
                .accessibilityHidden(true)
        } else {
            PersonAvatar(name: name, size: 52)
        }
    }

    private func field(_ which: PersonField, label: LocalizedStringKey, prompt: LocalizedStringKey, text: Binding<String>) -> some View {
        let isFocused: Bool = focused == which
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
            // Örnek metin alanın üstünde soluk çizilir: AppKit odaksız alanın yer tutucusunu alanın yazı rengiyle
            // çiziyordu (girilmiş değer gibi görünüyordu). Bu yüzden alanın başlığı boş (AppKit yer tutucu çizmez), adı
            // erişilebilirlik etiketinde; tıklama alana geçer.
            TextField(text: text) { EmptyView() }
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(label))
                .focused($focused, equals: which)
                .appFont(size: 14, weight: .regular)
                .overlay(alignment: .leading) {
                    if text.wrappedValue.isEmpty {
                        Text(prompt)
                            .appFont(size: 14, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            // Örnek e-posta bağlantıya dönüşüp vurgu renginde çiziliyordu.
                            .tint(Theme.muted)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isFocused ? appearance.accent.color : Theme.line, lineWidth: isFocused ? 1.5 : 1)
                )
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}

/// Kişinin sayfası: başlık (rozet, ad, ünvan, e-posta, sesi; düzenle ve kaldır), özet sayılar, toplantıları ve
/// görevleri. Kaldırma iki adımlıdır (yanlışlıkla tıklanmasın).
private struct PersonDetail: View {
    let person: PersonSummary
    let router: MainWindowRouter
    /// Sor'un okuyabileceği toplantısı var (örnek toplantıdaki kurgusal kişide yok): "Sor" düğmesi görünür.
    let hasAskableMeetings: Bool
    let onSave: @MainActor (String, String, String) -> Void
    let onRemove: @MainActor () -> Void
    /// Pencereyi kapatır.
    let onClose: @MainActor () -> Void
    @State private var isEditing: Bool = false
    @State private var confirmRemove: Bool = false

    var body: some View {
        if isEditing {
            PersonForm(
                title: "Kişiyi düzenle", initialName: person.name, lockedName: person.isSaved && person.meetings.isEmpty ? nil : person.name,
                initialRole: person.role, initialEmail: person.email
            ) { (name: String, role: String, email: String) -> Void in
                onSave(name, role, email)
                isEditing = false
            } onCancel: {
                isEditing = false
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    PersonAvatar(name: person.name, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name).appFont(size: 28, weight: .regular).tracking(-0.4)
                        if !person.role.isEmpty {
                            Text(person.role).appFont(size: 14, weight: .regular)
                        }
                        // E-posta ve ses durumu alt alta (yan yanayken e-posta kesiliyordu).
                        VStack(alignment: .leading, spacing: 4) {
                            if !person.email.isEmpty, let url = URL(string: "mailto:\(person.email)") {
                                Link(destination: url) {
                                    Label(person.email, systemImage: "envelope")
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                            Label(person.hasVoiceprint ? "Sesinden tanınıyor" : "Sesi henüz kayıtlı değil", systemImage: person.hasVoiceprint ? "waveform.badge.checkmark" : "waveform")
                                .foregroundStyle(Theme.muted)
                        }
                        .appFont(size: 13, weight: .regular)
                    }
                    Spacer(minLength: 12)
                    if confirmRemove {
                        HStack(spacing: 6) {
                            Text("Kaldırılsın mı?").appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
                            Button("Kaldır", role: .destructive) { onRemove() }
                            Button("Vazgeç") { confirmRemove = false }
                        }
                        .controlSize(.small)
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 6) {
                            // Kişinin toplantılarına sor: pencere kapanır, Sor paneli bu kişiyle açılır (⌘J ile aynı).
                            if hasAskableMeetings {
                                Button("Sor", systemImage: "sparkle") {
                                    onClose()
                                    router.askOverlay = .person(name: person.name)
                                    router.askFocusRequest += 1
                                }
                                .hoverHint("Bu kişiyle toplantılarına sor (⌘J)", alignment: .trailing, edge: .bottom)
                            }
                            Button("Düzenle", systemImage: "pencil") { isEditing = true }
                            Button("Kaldır", systemImage: "trash") { confirmRemove = true }
                                .hoverHint("Kişiler'den kaldırır ve sesini unutur; toplantılardaki adı kalır", alignment: .trailing, edge: .bottom)
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark")
                                    .appFont(size: 12, weight: .semibold)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.hoverCapsule)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel(Text("Kapat"))
                        }
                        .controlSize(.small)
                    }
                }
                .animation(.smooth(duration: 0.2), value: confirmRemove)
                HStack(spacing: 12) {
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
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TOPLANTILARI").appFont(size: 11, weight: .semibold).tracking(DesignTokens.labelTracking).foregroundStyle(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(Array(person.meetings.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonMeeting)) in
                                if item.offset > 0 {
                                    Rectangle().fill(Theme.line).frame(height: 1)
                                }
                                Button {
                                    router.selectedMeetingID = item.element.meetingID
                                    router.section = .meetings
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.element.title).appFont(size: 14, weight: .medium).lineLimit(1)
                                            Text(item.element.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                                                .appFont(size: 12, weight: .regular)
                                                .foregroundStyle(Theme.muted)
                                        }
                                        Spacer(minLength: 8)
                                        // Kişinin bu toplantıdaki konuşma payı (etiketsiz yüzde neyin oranı olduğunu söylemiyordu).
                                        Text("Konuşma payı \(item.element.fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))")
                                            .appFont(size: 12, weight: .medium)
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.muted)
                                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                    }
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.hoverPlain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .cardSurface(cornerRadius: 14)
                    }
                }
                if !person.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("GÖREVLERİ").appFont(size: 11, weight: .semibold).tracking(DesignTokens.labelTracking).foregroundStyle(Theme.muted)
                        ForEach(Array(person.tasks.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonTask)) in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.element.task.description).appFont(size: 14, weight: .regular).fixedSize(horizontal: false, vertical: true)
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
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).appFont(size: 22, weight: .regular).tracking(-0.4)
            Text(label).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}

/// Şirketin sayfası: başlık (harf karosu, ad, alan adı), özet sayılar, kişileri (dokununca kişinin sayfası aynı
/// pencerede) ve toplantıları (dokununca toplantı açılır, kişinin sayfasındaki gibi).
private struct CompanyDetail: View {
    let company: CompanySummary
    let router: MainWindowRouter
    let onOpenPerson: @MainActor (String) -> Void
    /// Pencereyi kapatır.
    let onClose: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    CompanyTile(name: company.name, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: company.name).appFont(size: 28, weight: .regular).tracking(-0.4)
                            if company.isOwn {
                                OwnCompanyBadge()
                            }
                        }
                        Label(company.domain, systemImage: "globe")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 12)
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .appFont(size: 12, weight: .semibold)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.hoverCapsule)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("Kapat"))
                    .controlSize(.small)
                }
                HStack(spacing: 12) {
                    stat(value: "\(company.people.count)", label: "kişi")
                    stat(value: "\(company.meetingCount)", label: "toplantı")
                    stat(value: talkMinutes(seconds: company.totalSeconds), label: "konuşma")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("KİŞİLERİ").appFont(size: 11, weight: .semibold).tracking(DesignTokens.labelTracking).foregroundStyle(Theme.muted)
                    VStack(spacing: 0) {
                        ForEach(Array(company.people.enumerated()), id: \.offset) { (item: (offset: Int, element: PersonSummary)) in
                            if item.offset > 0 {
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                            Button {
                                onOpenPerson(item.element.id)
                            } label: {
                                HStack(spacing: 12) {
                                    PersonAvatar(name: item.element.name, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.element.name).appFont(size: 14, weight: .medium).lineLimit(1)
                                        Text(item.element.role.isEmpty ? item.element.email : item.element.role)
                                            .appFont(size: 12, weight: .regular)
                                            .foregroundStyle(Theme.muted)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverPlain)
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
                        Text("TOPLANTILARI").appFont(size: 11, weight: .semibold).tracking(DesignTokens.labelTracking).foregroundStyle(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(Array(company.meetings.enumerated()), id: \.offset) { (item: (offset: Int, element: CompanyMeeting)) in
                                if item.offset > 0 {
                                    Rectangle().fill(Theme.line).frame(height: 1)
                                }
                                Button {
                                    router.selectedMeetingID = item.element.meetingID
                                    router.section = .meetings
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.element.title).appFont(size: 14, weight: .medium).lineLimit(1)
                                            Text(item.element.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                                                .appFont(size: 12, weight: .regular)
                                                .foregroundStyle(Theme.muted)
                                        }
                                        Spacer(minLength: 8)
                                        // Şirketten bu toplantıda konuşanlar.
                                        Text(verbatim: item.element.people.formatted(.list(type: .and).locale(interfaceLocale())))
                                            .appFont(size: 12, weight: .medium)
                                            .foregroundStyle(Theme.muted)
                                            .lineLimit(1)
                                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                    }
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.hoverPlain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .cardSurface(cornerRadius: 14)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).appFont(size: 22, weight: .regular).tracking(-0.4)
            Text(label).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}
