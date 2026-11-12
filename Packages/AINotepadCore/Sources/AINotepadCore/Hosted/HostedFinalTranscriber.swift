import Foundation
import os
import Security

private let finalLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedFinal")

/// Abonelik sürümünün son geçişi: kayıt (dönüştürülmemişse kayıpsız `.caf`'ın kendisi; bkz.
/// `FinalPassSource.originalRecording`) 16 kHz mono 16 bit kayıpsız FLAC parçalarına (≤95 MB, ≤60 dk; bkz.
/// `encodeHostedFlacChunk`, `hostedFlacChunkMaxSec`) çevrilir, her parça sunucunun `/v1/transcribe` ucuna (ElevenLabs
/// Scribe vekili, konuşmacı ayırma açık) sırayla gönderilir (sunucu toplantıda aynı anda tek yükleme kabul eder; sonraki
/// parça öncekinin yüklemesi sürerken kodlanır), sonuçlar parça konumlarıyla kaydırılıp birleştirilir; ardışık parçalar
/// bir dakika örtüşür ve konuşmacılar ortak bölgedeki kelimelerle eşlenir (bkz. `mergeChunkTranscriptions`). Sınır: ortak
/// dakikada konuşmayan kişi sonraki parçada yeni kişi olarak görünür (adlandırırken aynı ad verilebilir). Parçalar geçici
/// klasörde tutulur ve iş bitince silinir. Parçaların ilerlemesi kaydın yanına yazılır (`HostedFinalPassProgress`):
/// yarıda kalan son geçiş tamamlanan parçaları yeniden yüklemez.
public struct HostedFinalTranscriber: FinalTranscriber {
    /// Ses sunucuda yazıya dökülür: dönüştürmeyle aynı anda, kayıpsız kayıttan başlar.
    public let source: FinalPassSource = .originalRecording
    private let client: HostedClient
    /// Sesin sayıldığı toplantı oturumu (kayıt bitince ek süre boyunca açıktır).
    private let meetingID: String
    /// Adlar ve terimler; sunucunun kabul ettiği biçime süzülür (bkz. `hostedKeyterms`).
    private let keyterms: [String]

    public init(client: HostedClient, meetingID: String, keyterms: [String]) {
        self.client = client
        self.meetingID = meetingID
        self.keyterms = keyterms
    }

    public func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-hosted-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.writeFailed(path: directory.path, reason: error.localizedDescription)
        }
        defer { removeChunkDirectory(directory: directory) }
        let pcm: HostedPcmFile = try writeHostedPcmFile(source: audioURL, directory: directory)
        let terms: [String] = hostedKeyterms(terms: keyterms, limit: 30)
        // Önceki (yarıda kalmış) işlemenin parçaları: tamamlananlar yeniden yüklenmez, yarıda kalan aynı anahtarla gider.
        let progressURL: URL = hostedFinalPassProgressURL(audioURL: audioURL)
        var progress: HostedFinalPassProgress = usableFinalPassProgress(progress: loadFinalPassProgress(url: progressURL), totalSamples: pcm.totalSamples)
        var results: [ChunkTranscription] = []
        var stopped: PartialFinalPass?
        var previous: AudioChunkFile?
        var pending: AudioChunkFile? = pcm.totalSamples > 0 ? try hostedChunk(pcm: pcm, startSample: 0, index: 0, directory: directory) : nil
        while let chunk = pending {
            let index: Int = results.count
            // Sonraki parça (bir saatten uzun kayıt) bu parça gönderilirken kodlanır. Bu parça başarısız olursa kodlama
            // kapsamdan çıkarken iptal edilip beklenir; sonucu kullanılmaz.
            async let following: AudioChunkFile? = followingHostedChunk(after: chunk, index: index + 1, pcm: pcm, directory: directory)
            let overlapSec: Double = previous.map { Double($0.span.startSample + $0.span.sampleCount - chunk.span.startSample) / Double(hostedTranscribeSampleRate) } ?? 0
            let durationSec: Double = Double(chunk.span.sampleCount) / Double(hostedTranscribeSampleRate)
            do {
                let saved: HostedChunkProgress? = resumableChunk(progress: progress, index: index, span: chunk.span)
                let data: Data
                if let response = saved?.response {
                    finalLogger.info("Son geçiş parçası önceki işlemeden alındı, parça: \(index + 1, privacy: .public)")
                    data = response
                } else {
                    let uploadKey: String = try saved?.uploadKey ?? makeUploadKey()
                    let started: HostedChunkProgress = HostedChunkProgress(
                        startSample: chunk.span.startSample, sampleCount: chunk.span.sampleCount, uploadKey: uploadKey, response: nil
                    )
                    progress = recordingChunk(progress: progress, index: index, chunk: started)
                    // The key is on disk before the chunk leaves, or the chunk is not sent (no second billing after a
                    // crash; see `saveFinalPassProgressBeforeUpload`).
                    try saveFinalPassProgressBeforeUpload(progress: progress, url: progressURL)
                    data = try await transcribeChunk(
                        url: chunk.url, languageCode: elevenLabsLanguageCode(languageMode: languageMode), keyterms: terms,
                        uploadKey: uploadKey, timeoutSec: hostedTranscribeTimeoutSec(durationSec: durationSec)
                    )
                    progress = recordingChunk(
                        progress: progress, index: index,
                        chunk: HostedChunkProgress(startSample: started.startSample, sampleCount: started.sampleCount, uploadKey: uploadKey, response: data)
                    )
                    saveFinalPassProgress(progress: progress, url: progressURL)
                }
                results.append(ChunkTranscription(
                    offsetSec: chunk.span.offsetSec(sampleRate: hostedTranscribeSampleRate), overlapSec: overlapSec, result: try parseElevenLabsResponse(data: data)
                ))
                finalLogger.info("Son geçiş parçası yazıya döküldü, parça: \(results.count, privacy: .public), saniye: \(durationSec, privacy: .public), bayt: \(chunk.bytes, privacy: .public)")
            } catch let error where !results.isEmpty && !(error is CancellationError) {
                // Sonraki parça reddedildi (ör. toplantının ses hakkı ya da aylık süre doldu) ya da bağlantı koptu:
                // yazıya dökülmüş (ve faturalanmış) parçalar atılmaz; kalan kısmın canlı metni korunur
                // (`coveredUntilSec`), neden bildirilir.
                stopped = partialFinalPass(lastDone: previous ?? chunk, error: error)
                break
            }
            previous = chunk
            do {
                pending = try await following
            } catch let error where !(error is CancellationError) {
                // Sonraki parça kodlanamadı: yazıya dökülenler korunur (yukarıdaki gibi).
                stopped = partialFinalPass(lastDone: chunk, error: error)
                break
            }
        }
        let merged: DiarizationResult = mergeChunkTranscriptions(chunks: results)
        return FinalPassResult(
            segments: finalSegments(words: merged.words, gapSec: 1.5),
            language: merged.languageCode.flatMap { meetingLanguage(elevenLabsCode: $0) },
            coverage: stopped.map { (stop: PartialFinalPass) -> FinalPassCoverage in .partial(coveredUntilSec: stop.coveredUntilSec, notice: stop.notice) }
                ?? .complete(notice: nil)
        )
    }
}

/// Yarıda kalan son geçişin uyarısı ve yazıya dökülen kaydın sonu (sn).
private struct PartialFinalPass {
    let notice: String
    let coveredUntilSec: Double
}

/// Yazıya dökülen son parça `lastDone` iken geçiş `error` yüzünden durdu: kalan kısımda canlı metin kullanılır.
private func partialFinalPass(lastDone: AudioChunkFile, error: any Error) -> PartialFinalPass {
    let covered: Double = lastDone.span.offsetSec(sampleRate: hostedTranscribeSampleRate) + Double(lastDone.span.sampleCount) / Double(hostedTranscribeSampleRate)
    let doneMinutes: Int = Int((covered / 60).rounded())
    let reason: String = (error as? HostedAPIError).map { hostedErrorMessage(error: $0) } ?? userFacingMessage(error: error)
    finalLogger.warning("Son geçiş yarıda kaldı, yazıya dökülen dakika: \(doneMinutes, privacy: .public), hata: \(String(describing: error), privacy: .private)")
    return PartialFinalPass(
        notice: String(localized: "Kaydın ilk \(doneMinutes) dakikası yeniden yazıya döküldü; kalanında canlı metin kullanıldı: \(reason)"),
        coveredUntilSec: covered
    )
}

/// Sunucunun parça sınırlarıyla (`hostedTranscribeMaxBytes`, `hostedFlacChunkMaxSec`, `hostedChunkOverlapSec`) FLAC parçası.
private func hostedChunk(pcm: HostedPcmFile, startSample: Int, index: Int, directory: URL) throws -> AudioChunkFile {
    try encodeHostedFlacChunk(
        pcm: pcm, startSample: startSample, index: index, directory: directory, maxBytes: hostedTranscribeMaxBytes,
        maxSamples: Int(hostedFlacChunkMaxSec * Double(hostedTranscribeSampleRate)),
        overlapSamples: Int(hostedChunkOverlapSec * Double(hostedTranscribeSampleRate))
    )
}

/// `chunk`'tan sonraki parça; kayıt bittiyse nil.
private func followingHostedChunk(after chunk: AudioChunkFile, index: Int, pcm: HostedPcmFile, directory: URL) async throws -> AudioChunkFile? {
    let overlapSamples: Int = Int(hostedChunkOverlapSec * Double(hostedTranscribeSampleRate))
    guard let start = nextHostedChunkStart(span: chunk.span, totalSamples: pcm.totalSamples, overlapSamples: overlapSamples) else {
        return nil
    }
    return try hostedChunk(pcm: pcm, startSample: start, index: index, directory: directory)
}

extension HostedFinalTranscriber {
    /// Parçayı gönderir. Sunucu aynı toplantının önceki yüklemesini hâlâ işliyorsa (`transcription_in_progress`, ör.
    /// bağlantı kopup istek yinelendiyse) beklenir ve en çok `hostedTranscribeBusyAttempts` kez yeniden denenir; her
    /// bekleme uyarı loglanır, sonra son hata fırlar. Toplantının sunucu oturumu kapandıysa (`meeting_not_active`:
    /// işleme süresi geçti ya da toplantı yeni kayıtla kapandı) bir kez yeniden işlemeye açılıp yinelenir; açılamazsa
    /// açma hatası fırlar.
    private func transcribeChunk(url: URL, languageCode: String?, keyterms: [String], uploadKey: String, timeoutSec: Double) async throws -> Data {
        var attempt: Int = 1
        var reopened: Bool = false
        while true {
            do {
                // Aynı parçanın her denemesi aynı anahtarla: önceki yanıt kaybolduysa sunucu saklı sonucu döndürür.
                return try await client.transcribe(meetingID: meetingID, flacFile: url, languageCode: languageCode, keyterms: keyterms, uploadKey: uploadKey, timeoutSec: timeoutSec)
            } catch let error as HostedAPIError where error.code == .transcriptionInProgress && attempt < hostedTranscribeBusyAttempts {
                finalLogger.warning("Toplantının önceki yüklemesi sürüyor, bekleniyor, deneme: \(attempt, privacy: .public)")
                try await Task.sleep(for: .seconds(hostedTranscribeBusyDelaySec))
                attempt += 1
            } catch let error as HostedAPIError where error.code == .meetingNotActive && !reopened {
                finalLogger.warning("Kaydın sunucu oturumu kapanmış, son geçiş için yeniden açılıyor")
                try await client.reopenRecordedMeeting(meetingID: meetingID)
                reopened = true
            }
        }
    }
}

/// Parçanın yükleme anahtarı: 32 rastgele bayt, dolgusuz base64url (sunucu yalnızca özetini saklar).
func makeUploadKey() throws -> String {
    var bytes: [UInt8] = [UInt8](repeating: 0, count: 32)
    let status: OSStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "SecRandomCopyBytes(uploadKey)", status: status)
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Geçici parça klasörünü siler; silinemezse uyarı loglanır (son geçişin sonucu etkilenmez, sistem geçici klasörü
/// kendisi temizler).
private func removeChunkDirectory(directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        finalLogger.warning("Geçici ses parçaları silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
    }
}
