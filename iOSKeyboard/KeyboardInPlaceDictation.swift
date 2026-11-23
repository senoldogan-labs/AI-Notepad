import AVFAudio
import Foundation
import KeyboardCore
import os
import Speech
import UIKit
import WebKit

private let inPlaceLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.hosted.Keyboard", category: "InPlaceDictation")

/// The longest in-place dictation (the app's `dictationMaxListeningSec`).
private let inPlaceMaxListeningSeconds: TimeInterval = 300

/// Dictation inside the keyboard, without opening Gistsmith (iOS 26+). A keyboard extension may not record
/// (`audiomxd`: "is an extension and doesn't have entitlements to record audio"), so a hidden web view captures the
/// microphone with `getUserMedia`: WebKit's media process records under Gistsmith's microphone permission. The samples
/// go to the on-device `SpeechAnalyzer` with `DictationTranscriber` (the model the app installed); no audio leaves the
/// iPhone and nothing is written to disk. The state is a `KeyboardDictation`, as the app would write it, so the keyboard
/// shows and inserts it like a dictation from Gistsmith's session. Technique from Hex (MIT, anomalyco/hex#1999).
@MainActor
final class KeyboardInPlaceDictation {
    /// The current dictation; nil when there is none (or it was inserted or dropped).
    private(set) var dictation: KeyboardDictation?
    /// Called on the main actor whenever `dictation` changes.
    var onChange: () -> Void = {}
    /// The dictation could not start here (no audio format, the analyzer or the capture failed before listening): it is
    /// dropped without a failure shown, and the keyboard hands the request to Gistsmith instead (the request id).
    var onUnavailable: (UUID) -> Void = { (_: UUID) -> Void in }
    /// The loudness (0…1) of each captured chunk while listening, for the voice field.
    var onLevel: (Double) -> Void = { (_: Double) -> Void in }
    private var capture: KeyboardWebMicrophone?
    private var transcriber: (any KeyboardInPlaceTranscribing)?
    private var attempt: UUID?
    private var capturedSeconds: Double = 0
    /// Samples captured while the analyzer still prepares: the microphone opens at once so the first words are kept.
    private var pending: [(samples: [Float], sampleRate: Double)] = []
    /// The user finished before the analyzer was up.
    private var finishWhenReady: Bool = false
    private var limit: Task<Void, Never>?
    /// The polished style's clean-up of the rule-formatted text (`KeyboardPolisher`, warmed at the start); nil when the
    /// dictation is written as spoken.
    private var polish: (@MainActor (String) async -> KeyboardPolishState)?
    /// The dictation language and options, for the rule formatting before the clean-up.
    private var languageCode: String = ""
    private var options: KeyboardDictationOptions = .standard
    /// Installed dictation locales, read when the keyboard appears (`refreshInstalledLocales`).
    private(set) var installedLocales: [String] = []

    /// iOS 26: `SpeechAnalyzer` and `DictationTranscriber`.
    static var isSupportedBySystem: Bool {
        if #available(iOS 26, *) {
            true
        } else {
            false
        }
    }

    var isActive: Bool {
        guard let phase = dictation?.phase else {
            return false
        }
        return phase == .preparing || phase == .listening || phase == .finishing
    }

    /// Reads which dictation models are installed (the keyboard never downloads one; Gistsmith does).
    func refreshInstalledLocales() async {
        guard #available(iOS 26, *) else {
            return
        }
        installedLocales = await DictationTranscriber.installedLocales.map(\.identifier)
    }

    /// The installed locale for the language, or nil.
    func locale(languageCode: String) -> String? {
        keyboardDictationLocale(languageCode: languageCode, installed: installedLocales, regionCode: Locale.current.region?.identifier)
    }

    /// Starts listening. `host` is the keyboard's view: the capture web view must be in the view hierarchy to run.
    /// `languageCode` and `options` write the text (`keyboardFormatDictation`); in the polished style the model is warmed
    /// now and cleans the text up once it is transcribed.
    func start(
        requestID: UUID, documentID: UUID?, localeIdentifier: String, contextualStrings: [String], languageCode: String, options: KeyboardDictationOptions,
        host: UIView
    ) {
        cancel()
        let attempt: UUID = UUID()
        self.attempt = attempt
        capturedSeconds = 0
        pending = []
        finishWhenReady = false
        self.languageCode = languageCode
        self.options = options
        set(KeyboardDictation(requestID: requestID, documentID: documentID, phase: .preparing, partialText: "", finalText: nil, failure: nil))
        guard #available(iOS 26, *) else {
            fail(attempt: attempt, failure: .unsupportedLanguage, reason: "iOS 26 required")
            return
        }
        if options.style == .polished {
            let polisher: KeyboardPolisher = KeyboardPolisher()
            polisher.prepare(languageCode: languageCode)
            polish = { (text: String) -> KeyboardPolishState in
                await polisher.polish(text: text, candidateLanguages: [languageCode], options: options)
            }
        }
        let capture: KeyboardWebMicrophone = self.capture ?? KeyboardWebMicrophone(host: host)
        self.capture = capture
        capture.onEvent = { [weak self] (event: KeyboardWebMicrophone.Event) -> Void in
            self?.handle(event: event, attempt: attempt)
        }
        capture.start()
        Task { [weak self] in
            do {
                let transcriber: KeyboardSpeechTranscriber = try await KeyboardSpeechTranscriber.make(
                    localeIdentifier: localeIdentifier, contextualStrings: Array(contextualStrings.prefix(100))
                ) { (text: String) -> Void in
                    Task { @MainActor in
                        self?.partial(text: text, attempt: attempt)
                    }
                }
                guard let self, self.attempt == attempt else {
                    transcriber.cancel()
                    return
                }
                self.transcriber = transcriber
                let buffered: [(samples: [Float], sampleRate: Double)] = self.pending
                self.pending = []
                for chunk in buffered {
                    try transcriber.append(samples: chunk.samples, sampleRate: chunk.sampleRate)
                }
                if self.finishWhenReady {
                    self.finishTranscription(transcriber: transcriber, attempt: attempt)
                }
            } catch {
                self?.unavailable(attempt: attempt, reason: String(describing: error))
            }
        }
        limit = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(inPlaceMaxListeningSeconds))
            } catch {
                return
            }
            if self?.attempt == attempt {
                self?.finish()
            }
        }
    }

    /// Stops listening; the rest of the audio is transcribed and the dictation finishes with its text.
    func finish() {
        guard let current = dictation, let attempt, current.phase == .listening || current.phase == .preparing else {
            return
        }
        limit?.cancel()
        limit = nil
        capture?.stop()
        set(KeyboardDictation(
            requestID: current.requestID, documentID: current.documentID, phase: .finishing, partialText: current.partialText, finalText: nil,
            failure: nil
        ))
        guard let transcriber else {
            // Finished while the analyzer still prepares: the buffered audio is transcribed once it is up.
            finishWhenReady = true
            return
        }
        finishTranscription(transcriber: transcriber, attempt: attempt)
    }

    private func finishTranscription(transcriber: any KeyboardInPlaceTranscribing, attempt: UUID) {
        Task { [weak self] in
            do {
                let raw: String = try await transcriber.finish()
                self?.complete(attempt: attempt, raw: raw)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(attempt: attempt, failure: .failed, reason: String(describing: error))
            }
        }
    }

    /// Drops the dictation (cancelled, inserted, or the keyboard went away); nothing is inserted.
    func cancel() {
        limit?.cancel()
        limit = nil
        attempt = nil
        polish = nil
        transcriber?.cancel()
        transcriber = nil
        capture?.stop()
        if dictation != nil {
            set(nil)
        }
    }

    /// The keyboard is hidden: the dictation stops and the web view leaves (WebKit's process ends with it).
    func tearDown() {
        cancel()
        capture?.tearDown()
        capture = nil
    }

    private func handle(event: KeyboardWebMicrophone.Event, attempt: UUID) {
        guard self.attempt == attempt else {
            return
        }
        switch event {
        case .started(let sampleRate):
            inPlaceLogger.info("In-place capture started, rate: \(sampleRate, privacy: .public)")
            if let current = dictation, current.phase == .preparing {
                set(KeyboardDictation(
                    requestID: current.requestID, documentID: current.documentID, phase: .listening, partialText: "", finalText: nil, failure: nil
                ))
            }
        case .samples(let samples, let sampleRate):
            guard dictation?.phase == .listening else {
                return
            }
            capturedSeconds += Double(samples.count) / max(sampleRate, 1)
            onLevel(keyboardVoiceLevel(samples: samples))
            guard let transcriber else {
                pending.append((samples, sampleRate))
                return
            }
            do {
                try transcriber.append(samples: samples, sampleRate: sampleRate)
            } catch {
                fail(attempt: attempt, failure: .failed, reason: String(describing: error))
            }
        case .failed(let message):
            // E.g. NotAllowedError: Gistsmith's microphone permission was taken back since the app last said so.
            if transcriber == nil {
                unavailable(attempt: attempt, reason: message)
            } else {
                fail(attempt: attempt, failure: .failed, reason: message)
            }
        case .processTerminated:
            capture?.tearDown()
            capture = nil
            fail(attempt: attempt, failure: .failed, reason: "web content process terminated")
        }
    }

    private func partial(text: String, attempt: UUID) {
        guard self.attempt == attempt, let current = dictation, current.phase == .listening || current.phase == .finishing else {
            return
        }
        set(KeyboardDictation(
            requestID: current.requestID, documentID: current.documentID, phase: current.phase, partialText: text, finalText: nil, failure: nil
        ))
    }

    private func complete(attempt: UUID, raw: String) {
        guard self.attempt == attempt, let current = dictation else {
            return
        }
        transcriber = nil
        let text: String? = keyboardInPlaceText(raw: raw, capturedSeconds: capturedSeconds, minimumSeconds: keyboardInPlaceMinimumSeconds)
        guard let text, let polish else {
            set(KeyboardDictation(
                requestID: current.requestID, documentID: current.documentID, phase: text == nil ? .failed : .finished, partialText: "", finalText: text,
                failure: text == nil ? .noSpeech : nil
            ))
            return
        }
        // The keyboard shows "Polishing…" meanwhile; the heard words stay as the partial text (live typing).
        set(KeyboardDictation(
            requestID: current.requestID, documentID: current.documentID, phase: .finishing, partialText: text, finalText: nil, failure: nil,
            polish: .polishing
        ))
        let formatted: String = keyboardFormatDictation(text: text, languageCode: languageCode, options: options)
        Task { [weak self] in
            let state: KeyboardPolishState = await polish(formatted)
            guard let self, self.attempt == attempt, let current = self.dictation else {
                return
            }
            self.set(KeyboardDictation(
                requestID: current.requestID, documentID: current.documentID, phase: .finished, partialText: "", finalText: text, failure: nil, polish: state
            ))
        }
    }

    private func fail(attempt: UUID, failure: KeyboardDictationFailure, reason: String) {
        guard self.attempt == attempt, let current = dictation else {
            return
        }
        inPlaceLogger.error("In-place dictation failed, failure: \(failure.rawValue, privacy: .public), reason: \(reason, privacy: .public)")
        limit?.cancel()
        limit = nil
        transcriber?.cancel()
        transcriber = nil
        capture?.stop()
        set(KeyboardDictation(
            requestID: current.requestID, documentID: current.documentID, phase: .failed, partialText: "", finalText: nil, failure: failure
        ))
    }

    /// Before anything was transcribed: the dictation goes quietly and Gistsmith takes it over (`onUnavailable`).
    private func unavailable(attempt: UUID, reason: String) {
        // Nothing was transcribed yet (the analyzer never came up, or the capture failed before it did).
        guard self.attempt == attempt, let current = dictation, transcriber == nil else {
            fail(attempt: attempt, failure: .failed, reason: reason)
            return
        }
        inPlaceLogger.error("In-place dictation unavailable, handing over to Gistsmith, reason: \(reason, privacy: .public)")
        cancel()
        onUnavailable(current.requestID)
    }

    private func set(_ value: KeyboardDictation?) {
        dictation = value
        onChange()
    }
}

/// The speech side of an in-place dictation.
@MainActor
private protocol KeyboardInPlaceTranscribing: AnyObject {
    /// Feeds captured samples (mono Float32 at `sampleRate`).
    func append(samples: [Float], sampleRate: Double) throws
    /// Ends the input and returns the whole transcript.
    func finish() async throws -> String
    func cancel()
}

/// `SpeechAnalyzer` with a streaming `DictationTranscriber` (volatile results for the live text, frequent finalization
/// so little is left to transcribe after the finish), as the app's keyboard dictation (`AppleDictationEngine`).
@available(iOS 26, *)
@MainActor
private final class KeyboardSpeechTranscriber: KeyboardInPlaceTranscribing {
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let collector: Task<String, any Error>
    private let run: Task<Void, any Error>
    private var converter: (sourceRate: Double, converter: AVAudioConverter)?

    private init(
        analyzer: SpeechAnalyzer, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation, collector: Task<String, any Error>,
        run: Task<Void, any Error>
    ) {
        self.analyzer = analyzer
        self.format = format
        self.input = input
        self.collector = collector
        self.run = run
    }

    static func make(
        localeIdentifier: String, contextualStrings: [String], onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> KeyboardSpeechTranscriber {
        let module: DictationTranscriber = DictationTranscriber(
            locale: Locale(identifier: localeIdentifier), contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw KeyboardInPlaceError.noAudioFormat(locale: localeIdentifier)
        }
        let analyzer: SpeechAnalyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)
        if !contextualStrings.isEmpty {
            let context: AnalysisContext = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        let collector: Task<String, any Error> = Task.detached {
            var finalized: [String] = []
            var volatile: String = ""
            for try await result in module.results {
                let text: String = String(result.text.characters)
                if result.isFinal {
                    finalized.append(text)
                    volatile = ""
                } else {
                    volatile = text
                }
                onPartial(keyboardJoinedTranscript(finalized: finalized, volatile: volatile))
            }
            return keyboardJoinedTranscript(finalized: finalized, volatile: "")
        }
        let (stream, continuation): (AsyncStream<AnalyzerInput>, AsyncStream<AnalyzerInput>.Continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let run: Task<Void, any Error> = Task.detached {
            try await analyzer.start(inputSequence: stream)
        }
        return KeyboardSpeechTranscriber(analyzer: analyzer, format: format, input: continuation, collector: collector, run: run)
    }

    func append(samples: [Float], sampleRate: Double) throws {
        guard !samples.isEmpty else {
            return
        }
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData?[0] else {
            throw KeyboardInPlaceError.conversion(reason: "source buffer, \(samples.count) samples at \(sampleRate) Hz")
        }
        samples.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<Float>) -> Void in
            if let base = pointer.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        if converter?.sourceRate != sampleRate {
            guard let made = AVAudioConverter(from: sourceFormat, to: format) else {
                throw KeyboardInPlaceError.conversion(reason: "no converter from \(sourceFormat) to \(format)")
            }
            converter = (sampleRate, made)
        }
        guard let converter = converter?.converter else {
            return
        }
        let capacity: AVAudioFrameCount = AVAudioFrameCount((Double(samples.count) * format.sampleRate / sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw KeyboardInPlaceError.conversion(reason: "output buffer, capacity \(capacity)")
        }
        nonisolated(unsafe) var supplied: Bool = false
        nonisolated(unsafe) let pending: AVAudioPCMBuffer = source
        var conversionError: NSError?
        let status: AVAudioConverterOutputStatus = converter.convert(to: output, error: &conversionError) { (_: AVAudioPacketCount, outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return pending
        }
        if status == .error {
            throw KeyboardInPlaceError.conversion(reason: conversionError.map { String(describing: $0) } ?? "status error")
        }
        if output.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: output))
        }
    }

    func finish() async throws -> String {
        input.finish()
        try await run.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    func cancel() {
        input.finish()
        run.cancel()
        collector.cancel()
        let analyzer: SpeechAnalyzer = analyzer
        Task.detached {
            await analyzer.cancelAndFinishNow()
        }
    }
}

/// The transcript's parts, trimmed and joined with one space (empty parts skipped). Pure function.
private func keyboardJoinedTranscript(finalized: [String], volatile: String) -> String {
    (finalized + [volatile])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

enum KeyboardInPlaceError: Error {
    case noAudioFormat(locale: String)
    case conversion(reason: String)
}

/// The hidden web view that records: `getUserMedia` in a 2×2 pt page posts 16-bit PCM to Swift. The page is loaded
/// from a string with an https base URL (a secure context, which `getUserMedia` requires); the media capture request is
/// granted for the microphone only. Recording stops with `stop` or when the keyboard goes.
@MainActor
final class KeyboardWebMicrophone: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Event {
        case started(sampleRate: Double)
        case samples([Float], sampleRate: Double)
        case failed(String)
        case processTerminated
    }

    var onEvent: (Event) -> Void = { (_: Event) -> Void in }
    private let webView: WKWebView
    private var isLoaded: Bool = false
    private var startWhenLoaded: Bool = false
    private var sampleRate: Double = 48_000

    init(host: UIView) {
        let configuration: WKWebViewConfiguration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        super.init()
        configuration.userContentController.add(KeyboardWeakMessageHandler(target: self), name: "gistsmith")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        webView.alpha = 0.02
        host.addSubview(webView)
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://keyboard.gistsmith.local/"))
    }

    func start() {
        guard isLoaded else {
            startWhenLoaded = true
            return
        }
        webView.evaluateJavaScript("gistsmithStart()")
    }

    func stop() {
        startWhenLoaded = false
        guard isLoaded else {
            return
        }
        webView.evaluateJavaScript("gistsmithStop()")
    }

    func tearDown() {
        onEvent = { (_: Event) -> Void in }
        startWhenLoaded = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "gistsmith")
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        if startWhenLoaded {
            startWhenLoaded = false
            start()
        }
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        onEvent(.processTerminated)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return
        }
        switch type {
        case "started":
            sampleRate = (body["rate"] as? Double) ?? 48_000
            onEvent(.started(sampleRate: sampleRate))
        case "pcm":
            guard let encoded = body["data"] as? String, let data = Data(base64Encoded: encoded) else {
                return
            }
            onEvent(.samples(keyboardPCMSamples(int16LittleEndian: data), sampleRate: sampleRate))
        case "error":
            onEvent(.failed((body["message"] as? String) ?? "unknown"))
        default:
            break
        }
    }

    /// Mono, no echo cancellation or gain control (dictation wants the voice as spoken); 4096-frame chunks (~85 ms at
    /// 48 kHz). A stop while the start still waits for the microphone releases what that start opens.
    private static let page: String = """
    <!doctype html><meta charset="utf-8"><script>
    let ctx = null, stream = null, source = null, node = null, running = false, generation = 0;
    const post = (m) => webkit.messageHandlers.gistsmith.postMessage(m);
    const release = (s, c) => { if (s) s.getTracks().forEach((t) => t.stop()); if (c) c.close().catch(() => {}); };
    async function gistsmithStart() {
      if (running) return;
      running = true;
      const start = ++generation;
      const stale = () => start !== generation;
      let s = null, c = null;
      try {
        s = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
        if (stale()) return release(s);
        c = new AudioContext();
        await c.resume();
        if (stale()) return release(s, c);
        stream = s; ctx = c;
        source = ctx.createMediaStreamSource(stream);
        node = ctx.createScriptProcessor(4096, 1, 1);
        node.onaudioprocess = (event) => {
          if (!running) return;
          const input = event.inputBuffer.getChannelData(0);
          const pcm = new Int16Array(input.length);
          for (let i = 0; i < input.length; i++) {
            const v = Math.max(-1, Math.min(1, input[i]));
            pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
          }
          const bytes = new Uint8Array(pcm.buffer);
          let binary = "";
          for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          post({ type: "pcm", data: btoa(binary) });
        };
        source.connect(node);
        node.connect(ctx.destination);
        post({ type: "started", rate: ctx.sampleRate });
      } catch (error) {
        if (stale()) return release(s, c);
        running = false;
        release(s, c);
        post({ type: "error", message: (error && (error.name + ": " + error.message)) || String(error) });
      }
    }
    async function gistsmithStop() {
      generation++;
      running = false;
      try { if (node) node.disconnect(); if (source) source.disconnect(); } catch (e) {}
      if (stream) stream.getTracks().forEach((t) => t.stop());
      if (ctx) { try { await ctx.close(); } catch (e) {} }
      ctx = stream = source = node = null;
    }
    </script>
    """
}

/// Holds the message handler weakly: `WKUserContentController` retains its handlers, which would keep the capture alive.
private final class KeyboardWeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
