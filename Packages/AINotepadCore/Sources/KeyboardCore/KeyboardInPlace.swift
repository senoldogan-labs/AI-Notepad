import Foundation

/// How a tap on the keyboard's microphone dictates.
public enum KeyboardDictationRoute: Sendable, Hashable {
    /// Gistsmith's microphone session is live: the start goes to the app in place.
    case appSession
    /// The session's heartbeat is late: the start goes to the app in place, Gistsmith opens if it does not answer.
    case appSessionOrOpen
    /// The keyboard listens and transcribes by itself (iOS 26+): nothing opens.
    case inPlace
    /// Gistsmith opens to warm the microphone.
    case openApp
}

/// The route of a dictation start. A live session wins (its microphone is already warm and it detects the spoken
/// language); otherwise the keyboard dictates by itself when it can, and only then does Gistsmith open. Pure function.
public func keyboardDictationRoute(sessionIsLive: Bool, sessionMayBeAlive: Bool, inPlaceIsReady: Bool) -> KeyboardDictationRoute {
    if sessionIsLive {
        return .appSession
    }
    if sessionMayBeAlive {
        return .appSessionOrOpen
    }
    return inPlaceIsReady ? .inPlace : .openApp
}

/// Memory the keyboard must have left below iOS's limit for its extension before it dictates in place: the capture web
/// view and WebKit's first use, the speech analyzer's client side and the dictation panel, with margin (Hex measured
/// 58 MB of a ~176 MB limit on an iPhone 17 Pro, iOS 27.2). iOS ends a keyboard that passes its limit.
public let keyboardInPlaceHeadroomBytes: UInt64 = 40 * 1_048_576

/// Whether the keyboard may dictate in place: Full Access (the App Group), Gistsmith allowed the microphone (the
/// capture runs under the app's permission and cannot ask for it), an installed dictation model for the language
/// (the keyboard does not download one) and enough memory. `headroomBytes` 0 means iOS does not say (the Simulator).
/// Pure function.
public func keyboardInPlaceIsReady(hasFullAccess: Bool, microphoneAllowed: Bool, installedLocale: String?, headroomBytes: UInt64) -> Bool {
    guard hasFullAccess, microphoneAllowed, installedLocale != nil else {
        return false
    }
    return headroomBytes == 0 || headroomBytes >= keyboardInPlaceHeadroomBytes
}

/// The installed dictation locale for a language code ("tr", "nb"): the one in the user's region, then the language's
/// own country, then the first alphabetically; nil when none is installed. Identifiers may use "_" or "-". Pure function.
public func keyboardDictationLocale(languageCode: String, installed: [String], regionCode: String?) -> String? {
    let candidates: [String] = installed.filter { keyboardLocaleLanguage(identifier: $0) == languageCode.lowercased() }.sorted()
    let inRegion: (String) -> String? = { (region: String) -> String? in
        candidates.first { $0.replacingOccurrences(of: "-", with: "_").uppercased().hasSuffix("_" + region.uppercased()) }
    }
    let likelyRegion: String? = Locale.Language(identifier: languageCode).maximalIdentifier.split(separator: "-").last.map(String.init)
    return regionCode.flatMap(inRegion) ?? likelyRegion.flatMap(inRegion) ?? candidates.first
}

/// The language part of a locale identifier ("tr_TR" → "tr", "nb-NO" → "nb"), lowercased. Pure function.
public func keyboardLocaleLanguage(identifier: String) -> String {
    String(identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? "").lowercased()
}

/// Little-endian 16-bit PCM (what the capture page posts, base64-decoded) as Float32 samples in -1…1. A trailing odd
/// byte is dropped. Pure function.
public func keyboardPCMSamples(int16LittleEndian data: Data) -> [Float] {
    let count: Int = data.count / 2
    var samples: [Float] = []
    samples.reserveCapacity(count)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
        for index in 0..<count {
            let value: Int16 = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
            samples.append(Float(value) / 32768)
        }
    }
    return samples
}

/// The text a finished in-place dictation inserts: runs of spaces and tabs become one space, line breaks stay, the ends
/// are trimmed; nil when nothing is left or the capture was shorter than `minimumSeconds` (a slip of the finger).
/// Pure function.
public func keyboardInPlaceText(raw: String, capturedSeconds: Double, minimumSeconds: Double) -> String? {
    guard capturedSeconds >= minimumSeconds else {
        return nil
    }
    let text: String = raw
        .components(separatedBy: .newlines)
        .map { (line: String) -> String in line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// The shortest capture an in-place dictation transcribes (the app's `keyboardMinimumSamples`, 4000 at 16 kHz).
public let keyboardInPlaceMinimumSeconds: Double = 0.25

/// How loud a chunk of the voice is, 0…1: its RMS in decibels mapped from -55 dB (silence, 0) to -12 dB (a close voice,
/// 1). Drives the dictation waveform. Pure function.
public func keyboardVoiceLevel(samples: [Float]) -> Double {
    guard !samples.isEmpty else {
        return 0
    }
    let meanSquare: Float = samples.reduce(0) { (sum: Float, sample: Float) -> Float in sum + sample * sample } / Float(samples.count)
    let decibels: Double = 10 * log10(Double(max(meanSquare, 1e-10)))
    return min(1, max(0, (decibels + 55) / 43))
}

/// The waveform's recent levels, newest last, at most `limit`: the bars scroll right to left as the voice goes on.
/// Pure function.
public func keyboardLevelHistory(history: [Double], appending level: Double, limit: Int) -> [Double] {
    Array((history + [level]).suffix(limit))
}
