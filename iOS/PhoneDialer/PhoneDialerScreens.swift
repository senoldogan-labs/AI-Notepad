#if PHONE_DIALER
import AINotepadCore
import AINotepadUI
import SwiftUI

/// The dialer's steps (`phoneDialerStep`): introduction, verifying the user's own number, the recording terms, then the
/// keypad. The in-call screen covers them while a call runs, and turns into the after-call screen when it ends.
struct PhoneDialerScreen: View {
    @Bindable var dialer: PhoneDialer
    /// "Other ways to record a call": the phone call guide (iPhone's own call recording, the Mac).
    let onOtherWays: @MainActor () -> Void
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder

    var body: some View {
        Group {
            if let status = dialer.status, let step = dialer.step {
                VStack(spacing: 0) {
                    if let index = step.setupIndex {
                        SetupProgress(index: index, total: phoneDialerSetupSteps)
                            .padding(.horizontal, 20)
                            .padding(.top, 6)
                    }
                    stepView(step: step, status: status)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        .id(stepKey(step: step))
                }
                .animation(.smooth(duration: 0.3), value: stepKey(step: step))
            } else if let error = dialer.statusError {
                NoticeText(error, severity: .error)
                    .appFont(size: 13, weight: .regular)
                    .padding(20)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .fullScreenCover(item: $dialer.activeCall) { (_: PhoneActiveCall) in
            PhoneInCallView(dialer: dialer)
        }
    }

    /// One identity per screen (the code screen keeps its identity while the code is the same).
    private func stepKey(step: PhoneDialerStep) -> String {
        switch step {
        case .intro: "intro"
        case .verifyNumber: "verify"
        case .enterCode: "code"
        case .consent: "consent"
        case .dial: "dial"
        }
    }

    @ViewBuilder
    private func stepView(step: PhoneDialerStep, status: HostedPhoneStatus) -> some View {
        switch step {
        case .intro:
            PhoneDialerIntroView(status: status, onStart: dialer.finishIntro, onOtherWays: onOtherWays)
        case .verifyNumber:
            PhoneNumberVerificationView(dialer: dialer, status: status)
        case .enterCode(let code, let e164):
            PhoneVerificationCodeView(code: code, e164: e164, onChangeNumber: dialer.resetVerification)
        case .consent:
            PhoneDialerConsentView(status: status) { await dialer.acceptConsent(recorder: recorder) }
        case .dial:
            PhoneKeypadView(dialer: dialer, status: status)
        }
    }
}

// MARK: Shared pieces

/// "Step 2 of 3" over three segments in the accent colour.
private struct SetupProgress: View {
    let index: Int
    let total: Int
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { (segment: Int) in
                    Capsule()
                        .fill(segment <= index ? appearance.accent.color : Theme.soft)
                        .frame(height: 4)
                }
            }
            Text("Adım \(index) / \(total)")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Adım \(index) / \(total)"))
    }
}

/// A step's title and its one-paragraph lead.
private struct StepHeader: View {
    let title: Text
    let lead: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .appFont(size: 26, weight: .semibold)
                .foregroundStyle(Theme.ink)
                // Large text: a long word shrinks a little instead of breaking mid-word.
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            lead
                .appFont(size: 15, weight: .regular)
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One explained point: a symbol tile, a short title and a sentence.
private struct ExplainedRow: View {
    let symbol: String
    let title: Text
    let detail: Text

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .appFont(size: 15, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                detail
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A step's scrolling body with its main button pinned to the bottom.
private struct StepLayout<Content: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                footer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(Theme.background)
        }
    }
}

/// The wide main button of a step.
private struct StepButton: View {
    let title: Text
    let symbol: String?
    let isBusy: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button { action() } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(.white)
                } else if let symbol {
                    Image(systemName: symbol)
                }
                title
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.accentPill)
        .controlSize(.large)
    }
}

/// The country's name in the user's language (`Suomi`/`Finland`/`Finlandiya`).
func phoneCountryName(_ country: PhoneDialCountry) -> String {
    Locale.current.localizedString(forRegionCode: country.rawValue) ?? country.rawValue
}

/// The flag and calling code that open the country list.
private struct CountryChip: View {
    let country: PhoneDialCountry
    let action: @MainActor () -> Void

    var body: some View {
        Button { action() } label: {
            HStack(spacing: 6) {
                Text(verbatim: country.flag)
                    .appFont(size: 20, weight: .regular)
                Text(verbatim: "+\(country.callingCode)")
                    .appFont(size: 17, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Ülke: \(phoneCountryName(country)), +\(country.callingCode)"))
        .accessibilityHint(Text("Ülke listesini açar"))
    }
}

/// The allowed countries with their flags, calling codes and the minutes left for each; searchable.
struct PhoneCountryPicker: View {
    let countries: [PhoneDialCountry]
    let status: HostedPhoneStatus
    @Binding var selection: PhoneDialCountry
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @State private var query: String = ""

    private var shown: [PhoneDialCountry] {
        let sorted: [PhoneDialCountry] = countries.sorted { phoneCountryName($0).localizedCompare(phoneCountryName($1)) == .orderedAscending }
        let needle: String = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            return sorted
        }
        return sorted.filter { phoneCountryName($0).localizedCaseInsensitiveContains(needle) || "+\($0.callingCode)".contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List(shown, id: \.self) { (country: PhoneDialCountry) in
                Button {
                    selection = country
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: country.flag)
                            .appFont(size: 26, weight: .regular)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: phoneCountryName(country))
                                .appFont(size: 16, weight: .medium)
                                .foregroundStyle(Theme.ink)
                            Text("\(status.remainingMinutes(country: country)) dk kaldı")
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Text(verbatim: "+\(country.callingCode)")
                            .appFont(size: 15, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                        Image(systemName: "checkmark")
                            .appFont(size: 14, weight: .semibold)
                            .foregroundStyle(appearance.accent.color)
                            .opacity(country == selection ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(country == selection ? .isSelected : [])
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Ülke ara"))
            .navigationTitle(Text("Ülke"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: 1. Introduction

/// What calling from Gistsmith does before anything is set up: the call, the recording and its notice, the carrier that
/// keeps the recording until the note is made (App Review 5.1.2(i): named before the number is sent to it), the limits,
/// and emergency calls.
struct PhoneDialerIntroView: View {
    let status: HostedPhoneStatus
    let onStart: @MainActor () -> Void
    let onOtherWays: @MainActor () -> Void

    var body: some View {
        let provider: String = status.provider ?? "Twilio"
        StepLayout {
            AccentSymbolTile(symbol: "phone.badge.waveform", size: 64)
            StepHeader(
                title: Text("Telefon görüşmelerinden not çıkar"),
                lead: Text("Numarayı Gistsmith'ten ara; görüşme kaydedilir, not, kararlar ve görevler yüz yüze kayıttaki gibi hazırlanır.")
            )
            VStack(alignment: .leading, spacing: 18) {
                ExplainedRow(
                    symbol: "phone.arrow.up.right", title: Text("Buradan ararsın"),
                    detail: Text("Arama internet üzerinden gider. Karşı taraf arayan olarak kendi numaranı görür.")
                )
                ExplainedRow(
                    symbol: "waveform", title: Text("İki taraf da kaydedilir"),
                    detail: Text("Karşı taraf açınca, bağlanmadan önce görüşmenin kaydedildiğini kendi dilinde duyar.")
                )
                ExplainedRow(
                    symbol: "clock", title: Text("Planına dahil"),
                    detail: Text("Ayda \(status.monthlyMinutes) dakikaya kadar, arama başına en çok \(status.maxCallMinutes) dakika; ek ücret yok. Bazı ülkelere aramalar bu süreyi daha hızlı kullanır.")
                )
                ExplainedRow(
                    symbol: "building.2", title: Text("\(provider) taşır"),
                    detail: Text("Numaran ve görüşme, doğrulama ve arama için ABD'deki \(provider)'ya gider; kayıt not hazırlanana dek (en çok bir gün) orada kalır, sonra silinir.")
                )
                ExplainedRow(
                    symbol: "light.beacon.max", title: Text("Acil aramalar için değil"),
                    detail: Text("Acil numaralar Telefon uygulamasında açılır.")
                )
            }
            HStack(spacing: 18) {
                Button { onOtherWays() } label: {
                    Text("Aramayı başka yoldan kaydet")
                        .appFont(size: 14, weight: .medium)
                }
                if let privacy = URL(string: "https://gistsmith.com/privacy") {
                    Link(destination: privacy) {
                        Text("Gizlilik politikası")
                            .appFont(size: 14, weight: .medium)
                    }
                }
            }
        } footer: {
            StepButton(title: Text("Başla"), symbol: nil, isBusy: false) { onStart() }
        }
    }
}

// MARK: 2. Own number

/// The national number field after a country chip; `country` changes with the chip or a typed `+code`.
private struct PhoneNumberField: View {
    @Binding var country: PhoneDialCountry
    @Binding var number: String
    let countries: [PhoneDialCountry]
    let status: HostedPhoneStatus
    @State private var picksCountry: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            CountryChip(country: country) { picksCountry = true }
            TextField(text: $number, prompt: Text(verbatim: phoneNumberExample(country: country))) {
                Text("Telefon numaran")
            }
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .appFont(size: 20, weight: .medium)
            .monospacedDigit()
            .focused($focused)
        }
        .padding(8)
        .padding(.trailing, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        .sheet(isPresented: $picksCountry) {
            PhoneCountryPicker(countries: countries, status: status, selection: $country)
        }
        .onChange(of: number) {
            // A pasted `+358 …` picks its country.
            if let e164 = phoneE164(input: number, country: country), phoneDialDigits(input: number).hasPrefix("+"),
               let typed = phoneCountry(e164: e164), countries.contains(typed) {
                country = typed
            }
        }
        .onAppear { focused = true }
    }
}

/// A sample national number for the field's placeholder. Pure function.
func phoneNumberExample(country: PhoneDialCountry) -> String {
    switch country {
    case .us, .ca: "415 555 0100"
    case .fi: "40 123 4567"
    case .gb: "7700 900123"
    case .tr: "532 123 4567"
    }
}

/// Verifying the user's own number: the provider calls it and the user types the code shown on the next screen.
struct PhoneNumberVerificationView: View {
    let dialer: PhoneDialer
    let status: HostedPhoneStatus
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder
    @State private var number: String = ""
    @State private var country: PhoneDialCountry = .us
    @State private var didPickDefault: Bool = false

    var body: some View {
        let provider: String = status.provider ?? "Twilio"
        StepLayout {
            StepHeader(
                title: Text("Numaranı doğrula"),
                lead: Text("Aradığın kişiler arayan olarak bu numarayı görür. Senin olduğunu doğrulamak için seni arayacağız; aramayı açıp kodu tuşlayacaksın.")
            )
            PhoneNumberField(country: $country, number: $number, countries: status.callerCountries, status: status)
            if case .failed(let message) = dialer.verification {
                NoticeText(message, severity: .error)
                    .appFont(size: 13, weight: .regular)
            }
            Text("Arama \(provider)'dan, İngilizce bir sesle gelir. Günde en çok 5 doğrulama araması yapılabilir.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            StepButton(title: Text("Beni ara"), symbol: "phone.arrow.down.left", isBusy: dialer.verification == .starting) {
                Task { await dialer.startVerification(input: number, country: country, recorder: recorder) }
            }
            .disabled(phoneE164(input: number, country: country) == nil || dialer.verification == .starting)
        }
        .onAppear {
            guard !didPickDefault, let start = dialer.defaultCountry(allowed: status.callerCountries) else {
                return
            }
            country = start
            didPickDefault = true
        }
    }
}

/// The verification call is ringing: the code to type on it, digit by digit.
struct PhoneVerificationCodeView: View {
    let code: String
    let e164: String
    let onChangeNumber: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        StepLayout {
            StepHeader(
                title: Text("Aramayı aç"),
                lead: Text("\(phoneNumberDisplay(e164: e164)) aranıyor. Aramayı aç ve sorulunca bu kodu tuşla:")
            )
            HStack(spacing: 8) {
                ForEach(Array(code.enumerated()), id: \.offset) { (_: Int, digit: Character) in
                    Text(verbatim: String(digit))
                        .appFont(size: 30, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(appearance.accent.color.opacity(0.35)))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Kod: \(code.map(String.init).joined(separator: " "))"))
            HStack(spacing: 10) {
                ProgressView()
                Text("Doğrulama bekleniyor…")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        } footer: {
            Button { onChangeNumber() } label: {
                Text("Başka numara gir")
                    .appFont(size: 15, weight: .medium)
            }
        }
    }
}

// MARK: 3. Recording terms

/// The recording terms before the first call (App Review 2.5.14): the notice the callee hears, telling everyone on the
/// call, and each allowed country's rule. The user opts in explicitly (`POST /v1/phone/consent`).
struct PhoneDialerConsentView: View {
    let status: HostedPhoneStatus
    let onAccept: @MainActor () async -> Void
    @State private var understood: Bool = false
    @State private var isSaving: Bool = false

    /// The allowed countries by their recording rule, in a fixed order.
    private var groups: [(rule: PhoneRecordingRule, countries: [PhoneDialCountry])] {
        let order: [PhoneRecordingRule] = [.informAll, .mixed, .oneParty, .allParty]
        return order.compactMap { (rule: PhoneRecordingRule) -> (rule: PhoneRecordingRule, countries: [PhoneDialCountry])? in
            let countries: [PhoneDialCountry] = status.countries.filter { $0.recordingRule == rule }
            return countries.isEmpty ? nil : (rule, countries)
        }
    }

    var body: some View {
        StepLayout {
            StepHeader(
                title: Text("Kaydetmeden önce"),
                lead: Text("Gistsmith'ten yaptığın her arama iki taraflı kaydedilir. Karşı tarafı bilgilendirmek senin sorumluluğunda.")
            )
            VStack(alignment: .leading, spacing: 18) {
                ExplainedRow(
                    symbol: "speaker.wave.2", title: Text("Otomatik duyuru"),
                    detail: Text("Karşı taraf açınca, bağlanmadan önce kaydı duyuran kısa bir mesaj duyar.")
                )
                ExplainedRow(
                    symbol: "person.2", title: Text("Herkese haber ver"),
                    detail: Text("Görüşmenin başında kaydettiğini söyle. Kabul etmeyen olursa aramayı kapat.")
                )
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Ülkelere göre")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                    .textCase(.uppercase)
                ForEach(groups, id: \.rule) { (group: (rule: PhoneRecordingRule, countries: [PhoneDialCountry])) in
                    HStack(alignment: .top, spacing: 12) {
                        Text(verbatim: group.countries.map(\.flag).joined())
                            .appFont(size: 18, weight: .regular)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: 48, alignment: .leading)
                            .accessibilityHidden(true)
                        ruleText(group.rule)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Bu bir hukuki danışmanlık değildir; kuralları ülkene ve sektörüne göre denetle.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: 18)
            if let privacy = URL(string: "https://gistsmith.com/privacy") {
                Link(destination: privacy) {
                    Text("Gizlilik politikası")
                        .appFont(size: 13, weight: .medium)
                }
            }
        } footer: {
            Toggle(isOn: $understood) {
                Text("Görüşmeye katılan herkese kaydı söyleyeceğimi ve gereken yerde onaylarını alacağımı kabul ediyorum.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
            StepButton(title: Text("Kabul et ve devam et"), symbol: nil, isBusy: isSaving) {
                isSaving = true
                Task {
                    await onAccept()
                    isSaving = false
                }
            }
            .disabled(!understood || isSaving)
        }
    }

    private func ruleText(_ rule: PhoneRecordingRule) -> Text {
        switch rule {
        case .informAll:
            Text("Avrupa (AB, AEA, Birleşik Krallık): veri koruma kuralları gereği kayıttan önce herkes bilgilendirilmeli.")
        case .mixed:
            Text("ABD: Kaliforniya, Florida, Illinois, Washington gibi bazı eyaletlerde herkesin onayı gerekir.")
        case .oneParty:
            Text("Kanada: taraflardan birinin onayı yeter; kişisel bilgilerin korunması yasası yine de haber vermeyi ister.")
        case .allParty:
            Text("Türkiye: görüşmedeki herkesin açık onayı gerekir.")
        }
    }
}

// MARK: 4. Keypad

/// One keypad key: the digit and its letters.
private struct KeypadKey: Identifiable {
    let digit: String
    let letters: String
    var id: String { digit }
}

private let keypadKeys: [KeypadKey] = [
    KeypadKey(digit: "1", letters: ""), KeypadKey(digit: "2", letters: "ABC"), KeypadKey(digit: "3", letters: "DEF"),
    KeypadKey(digit: "4", letters: "GHI"), KeypadKey(digit: "5", letters: "JKL"), KeypadKey(digit: "6", letters: "MNO"),
    KeypadKey(digit: "7", letters: "PQRS"), KeypadKey(digit: "8", letters: "TUV"), KeypadKey(digit: "9", letters: "WXYZ"),
    KeypadKey(digit: "*", letters: ""), KeypadKey(digit: "0", letters: "+"), KeypadKey(digit: "#", letters: ""),
]

/// The twelve round keys; holding 0 types `+` when `onPlus` is given.
private struct KeypadGrid: View {
    let onDigit: @MainActor (String) -> Void
    let onPlus: (@MainActor () -> Void)?

    var body: some View {
        Grid(horizontalSpacing: 22, verticalSpacing: 14) {
            ForEach(0..<4, id: \.self) { (row: Int) in
                GridRow {
                    ForEach(keypadKeys[(row * 3)..<(row * 3 + 3)]) { (key: KeypadKey) in
                        keyButton(key: key)
                    }
                }
            }
        }
    }

    private func keyButton(key: KeypadKey) -> some View {
        Button {
            onDigit(key.digit)
        } label: {
            VStack(spacing: 0) {
                Text(verbatim: key.digit)
                    .appFont(size: 30, weight: .regular)
                Text(verbatim: key.letters.isEmpty ? " " : key.letters)
                    .appFont(size: 9, weight: .semibold)
                    .tracking(1.5)
                    .foregroundStyle(Theme.muted)
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 74, height: 74)
            .background(Theme.soft, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(KeyPressStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            if key.digit == "0" {
                onPlus?()
            }
        })
        .accessibilityLabel(Text(verbatim: key.digit))
    }
}

/// A key dims while pressed, like the Phone app's.
private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The keypad: the country chip, the number as it is typed (formatted once it is a whole number), the keys, call and
/// delete; under them the caller ID, the minutes left for that country and the recording reminder.
struct PhoneKeypadView: View {
    let dialer: PhoneDialer
    let status: HostedPhoneStatus
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder
    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var number: String = ""
    @State private var chosen: PhoneDialCountry = .us
    @State private var didPickDefault: Bool = false
    @State private var picksCountry: Bool = false

    /// The chosen country, or the one a typed `+code` names.
    private var country: PhoneDialCountry {
        guard phoneDialDigits(input: number).hasPrefix("+"), let e164 = phoneE164(input: number, country: chosen), let typed = phoneCountry(e164: e164) else {
            return chosen
        }
        return typed
    }

    /// The countries this caller can reach: the server's, without the caller's own where its carriers block such calls.
    private var callable: [PhoneDialCountry] {
        status.countries.filter { (destination: PhoneDialCountry) -> Bool in
            status.callerCountry.map { !phoneCallerIdBlocked(caller: $0, destination: destination) } ?? true
        }
    }

    private var target: PhoneDialTarget {
        phoneDialTarget(input: number, country: chosen, allowed: status.countries, callerCountry: status.callerCountry)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                CountryChip(country: chosen) { picksCountry = true }
                Spacer()
                Text("\(status.remainingMinutes(country: country)) dk kaldı")
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            Spacer(minLength: 0)
            numberDisplay
            KeypadGrid(
                onDigit: { (digit: String) -> Void in number.append(digit) },
                onPlus: { number = String(number.dropLast()) + "+" }
            )
            HStack(spacing: 22) {
                Color.clear.frame(width: 74, height: 74)
                Button {
                    place()
                } label: {
                    Image(systemName: dialer.isPlacing ? "ellipsis" : "phone.fill")
                        .appFont(size: 28, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 74, height: 74)
                        .background(Color.green, in: Circle())
                        .opacity(number.isEmpty ? 0.45 : 1)
                }
                .buttonStyle(KeyPressStyle())
                .disabled(number.isEmpty || dialer.isPlacing)
                .accessibilityLabel(Text("Aramayı başlat"))
                Button {
                    number = String(number.dropLast())
                } label: {
                    Image(systemName: "delete.left.fill")
                        .appFont(size: 22, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 74, height: 74)
                }
                .buttonStyle(KeyPressStyle())
                .opacity(number.isEmpty ? 0 : 1)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in number = "" })
                .accessibilityLabel(Text("Sil"))
            }
            Spacer(minLength: 0)
            footer
        }
        .onChange(of: number) { dialer.keypadMessage = nil }
        .sheet(isPresented: $picksCountry) {
            PhoneCountryPicker(countries: callable, status: status, selection: $chosen)
        }
        .onAppear {
            guard !didPickDefault, let start = dialer.defaultCountry(allowed: callable) else {
                return
            }
            chosen = start
            didPickDefault = true
            picksCountry = dialer.previewOpensCountries
        }
    }

    /// The typed number, and under it what will happen: the country and a check mark, or why it can't be called.
    private var numberDisplay: some View {
        VStack(spacing: 6) {
            Text(verbatim: displayedNumber)
                .appFont(size: 34, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(number.isEmpty ? Theme.muted.opacity(0.5) : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .contextMenu {
                    Button("Yapıştır", systemImage: "doc.on.clipboard") {
                        number = phoneDialDigits(input: UIPasteboard.general.string ?? "")
                    }
                }
            Group {
                if let message = dialer.keypadMessage {
                    Text(message)
                        .foregroundStyle(Color.orange)
                } else if case .call(_, let callee) = target {
                    Label { Text(verbatim: phoneCountryName(callee)) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green) }
                        .foregroundStyle(Theme.muted)
                } else if case .blocked(let reason) = target {
                    blockedText(reason)
                        .foregroundStyle(Color.orange)
                } else {
                    Text(verbatim: " ")
                }
            }
            .appFont(size: 13, weight: .regular)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The national number grouped once it is whole; the digits as typed until then; the example while empty.
    private var displayedNumber: String {
        guard !number.isEmpty else {
            return phoneNumberExample(country: chosen)
        }
        if case .call(let e164, let callee) = target {
            return phoneDialDigits(input: number).hasPrefix("+") ? phoneNumberDisplay(e164: e164) : phoneNationalDisplay(e164: e164, country: callee)
        }
        return number
    }

    private func blockedText(_ reason: PhoneDialBlock) -> Text {
        switch reason {
        case .notAllowed: Text("Bu ülkedeki numaralar henüz aranamıyor.")
        case .premium: Text("Ücretli ve özel servis numaraları aranamaz.")
        case .unsupported: Text("Bu ülke desteklenmiyor.")
        case .callerIdBlocked: Text("Bu ülkenin operatörleri, yurt dışından gelen ve aynı ülkenin numarasını gösteren aramaları engelliyor.")
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let caller = status.number?.e164 {
                Text("Arayan numara: \(phoneNumberDisplay(e164: caller))")
            }
            Label { Text("Kaydedilir; karşı taraf bağlanmadan önce duyuruyu duyar.") } icon: {
                Image(systemName: "record.circle").foregroundStyle(Color.red)
            }
        }
        .appFont(size: 12, weight: .regular)
        .foregroundStyle(Theme.muted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func place() {
        Task {
            let action: PhoneDialAction = await dialer.call(input: number, country: chosen, recorder: recorder)
            switch action {
            case .openPhoneApp(let url):
                openURL(url)
            case .started:
                number = ""
            case .refused(let message):
                dialer.keypadMessage = message
            }
        }
    }
}

// MARK: 5. In call and after

/// The running call: a recording indicator for the whole call (App Review 2.5.14), who is called, the state and time,
/// mute, keypad (tones into the call), speaker and hang up. When the call ends it becomes the after-call screen: the
/// talk time and the recording on its way to a note (the existing import).
struct PhoneInCallView: View {
    let dialer: PhoneDialer
    @State private var showsKeypad: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if let call = dialer.activeCall {
                if case .ended(let duration) = call.phase {
                    PhoneCallEndedView(dialer: dialer, call: call, duration: duration)
                } else {
                    running(call: call)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .interactiveDismissDisabled()
        .onAppear { showsKeypad = dialer.previewOpensCallKeypad }
    }

    private func running(call: PhoneActiveCall) -> some View {
        VStack(spacing: 22) {
            RecordingPill()
                .padding(.top, 14)
            VStack(spacing: 8) {
                if let country = phoneCountry(e164: call.e164) {
                    Text(verbatim: "\(country.flag)  \(phoneCountryName(country))")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
                Text(verbatim: phoneNumberDisplay(e164: call.e164))
                    .appFont(size: 30, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                TimelineView(.periodic(from: .now, by: 1)) { (context: TimelineViewDefaultContext) in
                    phaseText(call: call, now: context.date)
                        .appFont(size: 17, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
            if showsKeypad {
                VStack(spacing: 14) {
                    Text(verbatim: call.sentDigits.isEmpty ? " " : call.sentDigits)
                        .appFont(size: 26, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.head)
                    KeypadGrid(onDigit: { (digit: String) -> Void in Task { await dialer.sendDigit(digit) } }, onPlus: nil)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                HStack(spacing: 26) {
                    roundButton(symbol: call.isMuted ? "mic.slash.fill" : "mic.fill", title: Text("Sessiz"), isOn: call.isMuted) {
                        Task { await dialer.setMuted(!call.isMuted) }
                    }
                    roundButton(symbol: "circle.grid.3x3.fill", title: Text("Tuş takımı"), isOn: false) {
                        showsKeypad = true
                    }
                    roundButton(symbol: "speaker.wave.2.fill", title: Text("Hoparlör"), isOn: call.isSpeaker) {
                        dialer.setSpeaker(!call.isSpeaker)
                    }
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            ZStack {
                Button {
                    Task { await dialer.hangUp() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .appFont(size: 28, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(KeyPressStyle())
                .accessibilityLabel(Text("Aramayı bitir"))
                if showsKeypad {
                    HStack {
                        Spacer()
                        Button("Gizle") { showsKeypad = false }
                            .appFont(size: 16, weight: .medium)
                            .foregroundStyle(Theme.ink)
                            .padding(.trailing, 8)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: showsKeypad)
    }

    private func phaseText(call: PhoneActiveCall, now: Date) -> Text {
        switch call.phase {
        case .connecting:
            return Text("Arama başlatılıyor…")
        case .ringing:
            return Text("Çalıyor…")
        case .connected(let since):
            let elapsed: Int = Int(now.timeIntervalSince(since))
            let left: Int = (call.maxSeconds - elapsed) / 60
            let clock: String = Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))
            return left < 5 ? Text("\(clock) · kalan dakika: \(max(left, 0))") : Text(verbatim: clock)
        case .reconnecting:
            return Text("Yeniden bağlanıyor…")
        case .ended:
            return Text("Görüşme bitti")
        }
    }

    private func roundButton(symbol: String, title: Text, isOn: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button { action() } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .appFont(size: 24, weight: .medium)
                    .foregroundStyle(isOn ? Theme.background : Theme.ink)
                    .frame(width: 72, height: 72)
                    .background(isOn ? Theme.ink : Theme.soft, in: Circle())
                title
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The red "Recording" pill, pulsing gently while the call runs.
private struct RecordingPill: View {
    @State private var dim: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(dim ? 0.35 : 1)
            Text("Kaydediliyor")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(Color.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else {
                return
            }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// After the call: how long it lasted and the recording's way to a note (fetching, preparing, ready on the home screen).
private struct PhoneCallEndedView: View {
    let dialer: PhoneDialer
    let call: PhoneActiveCall
    let duration: Int?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let state: PhoneRecordingImport = phoneRecordingImport(callID: call.id, imports: dialer.recordingImports)
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            AccentSymbolTile(symbol: "phone.down", size: 64)
            VStack(spacing: 6) {
                Text("Görüşme bitti")
                    .appFont(size: 26, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: summary)
                    .appFont(size: 15, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            if let message = call.endMessage {
                NoticeText(message, severity: .error)
                    .appFont(size: 13, weight: .regular)
            }
            if state != .noRecording {
                VStack(alignment: .leading, spacing: 14) {
                    progressRow(title: Text("Kayıt alınıyor"), done: state == .importing || state == .imported, active: state == .waiting)
                    progressRow(title: Text("Not hazırlanıyor"), done: state == .imported, active: state == .importing)
                    progressRow(title: Text("Not ana ekranda"), done: state == .imported, active: false)
                    if case .failed(let message) = state {
                        NoticeText(message, severity: .attention)
                            .appFont(size: 13, weight: .regular)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(cornerRadius: 18)
                Text("Bu ekranı kapatabilirsin; not hazırlanınca ana ekranda görünür.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            StepButton(title: Text("Bitti"), symbol: nil, isBusy: false) { dialer.dismissEndedCall() }
        }
    }

    /// The number and the talk time (`+358 50 123 4567 · 12:34`).
    private var summary: String {
        let number: String = phoneNumberDisplay(e164: call.e164)
        guard let duration else {
            return number
        }
        return "\(number) · \(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))"
    }

    private func progressRow(title: Text, done: Bool, active: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(appearance.accent.color)
                } else if active {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Theme.line)
                }
            }
            .appFont(size: 20, weight: .regular)
            .frame(width: 24, height: 24)
            title
                .appFont(size: 15, weight: done || active ? .medium : .regular)
                .foregroundStyle(done || active ? Theme.ink : Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
