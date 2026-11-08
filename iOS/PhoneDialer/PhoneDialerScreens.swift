#if PHONE_DIALER
import AINotepadCore
import AINotepadUI
import SwiftUI

/// The dialer's card in the phone call guide: shown only when the server allows this account and country.
struct PhoneDialerCard: View {
    let dialer: PhoneDialer
    let onOpen: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AccentSymbolTile(symbol: "phone.arrow.up.right", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gistsmith'ten ara")
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text("Numarayı buradan ara; görüşme kaydedilir, not ve görevler yüz yüze kayıttaki gibi hazırlanır.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button { onOpen() } label: {
                Label { Text("Tuş takımını aç") } icon: { Image(systemName: "circle.grid.3x3.fill") }
            }
            .buttonStyle(.accentPill)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
    }
}

/// The dialer: the disclosure until accepted, then verifying the user's own number, then the keypad. The in-call screen
/// covers it while a call runs.
struct PhoneDialerScreen: View {
    @Bindable var dialer: PhoneDialer
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder

    var body: some View {
        Group {
            if let status = dialer.status {
                if !status.consentAccepted {
                    PhoneDialerConsentView(provider: status.provider ?? "Twilio") { await dialer.acceptConsent(recorder: recorder) }
                } else if status.number?.status != .verified {
                    PhoneNumberVerificationView(dialer: dialer)
                } else {
                    PhoneKeypadView(dialer: dialer, status: status)
                }
            } else if let error = dialer.statusError {
                NoticeText(error, severity: .error)
                    .appFont(size: 13, weight: .regular)
                    .padding(20)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .navigationTitle(Text("Gistsmith'ten ara"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await dialer.refresh(recorder: recorder) }
        .fullScreenCover(item: $dialer.activeCall) { (_: PhoneActiveCall) in
            PhoneInCallView(dialer: dialer)
        }
    }
}

/// One line of the disclosure: a symbol and a sentence.
private struct DisclosureLine: View {
    let symbol: String
    let text: Text

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AccentSymbolTile(symbol: symbol, size: 32)
            text
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The disclosure shown before first use (App Review 5.1.2(i), 2.5.14): what is recorded, who hears the notice, the
/// third party that carries and records the call, caller ID and emergency calls. The user opts in explicitly.
struct PhoneDialerConsentView: View {
    let provider: String
    let onAccept: @MainActor () async -> Void
    @State private var understood: Bool = false
    @State private var isSaving: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Aramalar kaydedilir")
                    .appFont(size: 22, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureLine(symbol: "waveform", text: Text("Gistsmith'ten yaptığın aramalar iki taraflı kaydedilir, yazıya dökülür ve not olur."))
                    DisclosureLine(symbol: "speaker.wave.2", text: Text("Karşı taraf bağlanmadan önce görüşmenin kaydedildiğini söyleyen bir duyuru duyar."))
                    DisclosureLine(symbol: "building.2", text: Text("Arama \(provider) üzerinden yapılır: \(provider) görüşmeyi taşır ve kaydı not hazırlanana dek (en çok bir gün) saklar, sonra silinir. Kayıt diğer kayıtların gibi yazıya dökülür."))
                    DisclosureLine(symbol: "person.crop.circle.badge.checkmark", text: Text("Arayan numara olarak yalnızca kendi numaran görünür; numaranı seni arayarak doğrularız."))
                    DisclosureLine(symbol: "light.beacon.max", text: Text("Acil aramalar Gistsmith'ten yapılamaz; acil numaralar Telefon uygulamasında açılır."))
                }
                NoticeText("Kaydetmeden önce karşı tarafa haber ver ve onayını al; birçok ülkede bu yasal zorunluluktur.", severity: .attention)
                    .appFont(size: 13, weight: .regular)
                Toggle(isOn: $understood) {
                    Text("Aramalarımın kaydedileceğini ve karşı tarafın onayını alacağımı kabul ediyorum.")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.ink)
                }
                Button {
                    isSaving = true
                    Task {
                        await onAccept()
                        isSaving = false
                    }
                } label: {
                    Text("Kabul et ve devam et")
                }
                .buttonStyle(.accentPill)
                .disabled(!understood || isSaving)
                if let privacy = URL(string: "https://gistsmith.com/privacy") {
                    Link(destination: privacy) {
                        Text("Gizlilik politikası")
                            .appFont(size: 13, weight: .medium)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }
}

/// Verifying the user's own number: the provider calls it and the user types the code shown here.
struct PhoneNumberVerificationView: View {
    let dialer: PhoneDialer
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder
    @State private var number: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Numaranı doğrula")
                    .appFont(size: 22, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text("Aradığın kişi arayan olarak kendi numaranı görür. Numaranın senin olduğunu doğrulamak için seni arayacağız; aramayı aç ve ekrandaki kodu tuşla.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                switch dialer.verification {
                case .waiting(let code, let e164):
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(phoneNumberDisplay(e164: e164)) aranıyor. Aramayı aç ve bu kodu tuşla:")
                            .appFont(size: 14, weight: .regular)
                            .foregroundStyle(Theme.ink)
                        Text(verbatim: code)
                            .appFont(size: 40, weight: .semibold)
                            .monospacedDigit()
                            .tracking(6)
                            .foregroundStyle(Theme.ink)
                            .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Doğrulama bekleniyor…")
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                    Button("Başka numara gir") { dialer.resetVerification() }
                        .appFont(size: 14, weight: .medium)
                default:
                    TextField(text: $number, prompt: Text(verbatim: "+1 415 555 0100")) {
                        Text("Telefon numaran")
                    }
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .appFont(size: 20, weight: .medium)
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                    if case .failed(let message) = dialer.verification {
                        NoticeText(message, severity: .error)
                            .appFont(size: 13, weight: .regular)
                    }
                    Button {
                        Task { await dialer.startVerification(input: number, recorder: recorder) }
                    } label: {
                        Label { Text("Beni ara") } icon: { Image(systemName: "phone.arrow.down.left") }
                    }
                    .buttonStyle(.accentPill)
                    .disabled(number.isEmpty || dialer.verification == .starting)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }
}

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

/// The keypad: the typed number, the keys (holding 0 types +), call and delete; under it the caller ID, the minutes
/// left and the recording reminder.
struct PhoneKeypadView: View {
    let dialer: PhoneDialer
    let status: HostedPhoneStatus
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder
    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var number: String = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Text(verbatim: number.isEmpty ? " " : number)
                .appFont(size: 32, weight: .medium)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .contextMenu {
                    Button("Yapıştır", systemImage: "doc.on.clipboard") {
                        number = phoneDialDigits(input: UIPasteboard.general.string ?? "")
                    }
                }
            if let message = dialer.keypadMessage {
                Text(message)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 22), count: 3), spacing: 16) {
                ForEach(keypadKeys) { (key: KeypadKey) in
                    keyButton(key: key)
                }
            }
            HStack(spacing: 22) {
                Color.clear.frame(width: 84, height: 72)
                Button {
                    place()
                } label: {
                    Image(systemName: "phone.fill")
                        .appFont(size: 28, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.green, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(number.isEmpty || dialer.isPlacing)
                .accessibilityLabel(Text("Aramayı başlat"))
                .frame(width: 84)
                Button {
                    number = String(number.dropLast())
                } label: {
                    Image(systemName: "delete.left")
                        .appFont(size: 22, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 84, height: 72)
                }
                .buttonStyle(.plain)
                .opacity(number.isEmpty ? 0 : 1)
                .accessibilityLabel(Text("Sil"))
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                if let caller = status.number?.e164 {
                    Text("Arayan numara: \(phoneNumberDisplay(e164: caller))")
                }
                Text("Bu ay kalan arama dakikası: \(status.remainingMinutes)")
                Label { Text("Kaydedilir; karşı taraf bağlanmadan önce duyuruyu duyar.") } icon: { Image(systemName: "record.circle") }
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onChange(of: number) { dialer.keypadMessage = nil }
    }

    private func keyButton(key: KeypadKey) -> some View {
        Button {
            number.append(key.digit)
        } label: {
            VStack(spacing: 0) {
                Text(verbatim: key.digit)
                    .appFont(size: 30, weight: .regular)
                Text(verbatim: key.letters)
                    .appFont(size: 10, weight: .semibold)
                    .tracking(1.5)
                    .foregroundStyle(Theme.muted)
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 76, height: 76)
            .background(Theme.soft, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            if key.digit == "0" {
                number = String(number.dropLast()) + "+"
            }
        })
        .accessibilityLabel(Text(verbatim: key.digit))
    }

    private func place() {
        Task {
            let action: PhoneDialAction = await dialer.call(input: number, recorder: recorder)
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

/// The running call: a recording indicator that stays visible for the whole call (App Review 2.5.14), the number, the
/// call's state and time, mute, speaker and hang up. After the call it says the note is being prepared.
struct PhoneInCallView: View {
    let dialer: PhoneDialer

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("Kaydediliyor")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Color.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.10), in: Capsule())
            .accessibilityElement(children: .combine)
            .padding(.top, 12)
            if let call = dialer.activeCall {
                VStack(spacing: 8) {
                    Text(verbatim: phoneNumberDisplay(e164: call.e164))
                        .appFont(size: 30, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    TimelineView(.periodic(from: .now, by: 1)) { (context: TimelineViewDefaultContext) in
                        phaseText(call: call, now: context.date)
                            .appFont(size: 16, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                if call.phase == .ended {
                    endedPanel(call: call)
                } else {
                    controls(call: call)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .interactiveDismissDisabled()
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

    private func controls(call: PhoneActiveCall) -> some View {
        HStack(spacing: 28) {
            roundButton(symbol: call.isMuted ? "mic.slash.fill" : "mic.fill", title: Text("Sessiz"), isOn: call.isMuted) {
                Task { await dialer.setMuted(!call.isMuted) }
            }
            Button {
                Task { await dialer.hangUp() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .appFont(size: 28, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Aramayı bitir"))
            roundButton(symbol: "speaker.wave.2.fill", title: Text("Hoparlör"), isOn: call.isSpeaker) {
                dialer.setSpeaker(!call.isSpeaker)
            }
        }
    }

    private func roundButton(symbol: String, title: Text, isOn: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button { action() } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .appFont(size: 22, weight: .medium)
                    .foregroundStyle(isOn ? Theme.background : Theme.ink)
                    .frame(width: 64, height: 64)
                    .background(isOn ? Theme.ink : Theme.soft, in: Circle())
                title
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func endedPanel(call: PhoneActiveCall) -> some View {
        VStack(spacing: 14) {
            if let message = call.endMessage {
                NoticeText(message, severity: .error)
                    .appFont(size: 13, weight: .regular)
            }
            switch phoneRecordingImport(callID: call.id, imports: dialer.recordingImports) {
            case .failed(let message):
                NoticeText(message, severity: .attention)
                    .appFont(size: 13, weight: .regular)
            case .imported:
                Text("Kayıt alındı; not ana ekranda hazırlanıyor.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
            case .noRecording:
                EmptyView()
            case .waiting, .importing:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Kayıt alınıyor; not ana ekranda hazırlanacak.")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
            }
            Button("Kapat") { dialer.dismissEndedCall() }
                .buttonStyle(.accentPill)
        }
    }
}
#endif
