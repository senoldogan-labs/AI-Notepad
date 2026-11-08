import Foundation
import Testing
@testable import AINotepadCore

/// Deponun `server/` klasörü (bu dosya `Packages/AINotepadCore/Tests/AINotepadCoreTests` içinde).
func serverDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "server", directoryHint: .isDirectory)
}

/// İstemcinin sunucuyla birebir aynı olması gereken listeleri: sunucu çalıştırılmaz, depodaki kaynak okunur; her
/// `swift test`te koşar.
@Suite struct ServerParityTests {
    // İstemcinin hata kodları sunucununkilerle birebir aynı olmalı (`HostedErrors.swift` bunu söyler): eksik kod
    // kullanıcıya "Sunucu beklenmeyen bir yanıt verdi (HTTP …)" olarak görünür (0.1.4'te `trial_not_started` böyleydi).
    @Test func clientKnowsEveryServerErrorCode() throws {
        let source: String = try String(contentsOf: serverDirectory().appending(path: "src/errors.ts"), encoding: .utf8)
        let union: Substring = try #require(source.firstRange(of: "export type ErrorCode =").map { source[$0.upperBound...] })
        let body: Substring = try #require(union.firstRange(of: ";").map { union[..<$0.lowerBound] })
        let serverCodes: Set<String> = Set(body.matches(of: #/"([a-z_]+)"/#).map { String($0.output.1) })
        #expect(serverCodes.count > 30)
        let clientCodes: Set<String> = Set(HostedErrorCode.allCases.map(\.rawValue))
        #expect(clientCodes.subtracting(serverCodes).isEmpty, "İstemcide olup sunucuda olmayan: \(clientCodes.subtracting(serverCodes).sorted())")
        let missing: [String] = serverCodes.subtracting(clientCodes).sorted()
        #expect(missing.isEmpty, "Sunucuda olup istemcide olmayan: \(missing)")
    }

    // Yapay zekâ amaçları ve telemetri listeleri sunucunun dizileriyle birebir aynı olmalı: eksik amaç 400
    // `llm_purpose_invalid`, eksik telemetri değeri `invalid_body` alır (istek düşer).
    @Test func telemetryListsMatchServer() throws {
        let purpose: String = try String(contentsOf: serverDirectory().appending(path: "src/llm/purpose.ts"), encoding: .utf8)
        #expect(try serverArray(source: purpose, name: "llmPurposes") == LLMPurpose.allCases.map(\.rawValue))
        let telemetry: String = try String(contentsOf: serverDirectory().appending(path: "src/telemetry.ts"), encoding: .utf8)
        #expect(try serverArray(source: telemetry, name: "telemetryCountKinds") == TelemetryCountKind.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryDurationKinds") == TelemetryDurationKind.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryIntegrations") == TelemetryIntegration.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryExportFormats") == TelemetryExportFormat.allCases.map(\.rawValue))
        #expect(try serverArray(source: telemetry, name: "telemetryLanguages") == ShareLanguage.allCases.map(\.rawValue))
    }

    // Abonelik hunisinin türleri ve değerleri sunucunun dizileriyle birebir aynı olmalı: eksik ya da fazla değer
    // `invalid_body` alır (gövdedeki bütün olaylar düşer).
    @Test func conversionListsMatchServer() throws {
        let conversion: String = try String(contentsOf: serverDirectory().appending(path: "src/conversion.ts"), encoding: .utf8)
        #expect(try serverArray(source: conversion, name: "conversionKinds") == ConversionEventKind.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionSurfaces") == ConversionSurface.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionTriggers") == ConversionTrigger.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionTiersOffered") == ConversionTiersOffered.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionTiers") == HostedTier.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionPlans") == HostedBillingPlan.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionReasons") == ConversionReason.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionRestoreResults") == ConversionRestoreResult.allCases.map(\.rawValue))
        #expect(try serverArray(source: conversion, name: "conversionChannels") == ConversionChannel.allCases.map(\.rawValue))
        // Gövdedeki katman alanının adı sunucunun şemasındaki (`tiersOffered`).
        #expect(conversion.contains("tiersOffered: z.enum(conversionTiersOffered)"))
    }

    // Günlük özellik raporunun alanları sunucunun şemasıyla birebir aynı olmalı (ör. `dictation`): şema katıdır, fazla
    // alan `invalid_body` alır, eksik zorunlu alan da.
    @Test func featureUsageFieldsMatchServer() throws {
        let telemetry: String = try String(contentsOf: serverDirectory().appending(path: "src/telemetry.ts"), encoding: .utf8)
        let start: Substring = try #require(telemetry.firstRange(of: "export const featureUsageSchema = z").map { telemetry[$0.upperBound...] })
        let body: Substring = try #require(start.firstRange(of: "\n  })").map { start[..<$0.lowerBound] })
        let serverFields: Set<String> = Set(body.matches(of: #/\n    ([A-Za-z]+):/#).map { String($0.output.1) })
        let usage: TelemetryFeatureUsage = emptyFeatureUsage(day: "2026-11-02")
        let json: Any = try JSONSerialization.jsonObject(with: try hostedFeatureUsageBody(usage: usage))
        let clientFields: Set<String> = Set(try #require(json as? [String: Any]).keys)
        #expect(serverFields.contains("dictation"))
        #expect(clientFields == serverFields, "İstemci: \(clientFields.sorted()), sunucu: \(serverFields.sorted())")
    }

    // İlk açılış hunisinin adımları ve ayrıntıları sunucunun dizileriyle birebir aynı olmalı: eksik değer
    // `invalid_body` alır (adım sayılmaz).
    @Test func funnelListsMatchServer() throws {
        let funnel: String = try String(contentsOf: serverDirectory().appending(path: "src/funnel.ts"), encoding: .utf8)
        #expect(try serverArray(source: funnel, name: "funnelSteps") == HostedFunnelStepKind.allCases.map(\.rawValue))
        #expect(try serverArray(source: funnel, name: "funnelSignInProviders") == HostedSignInProvider.allCases.map(\.rawValue))
        #expect(try serverArray(source: funnel, name: "funnelFailureStages") == HostedSignInFailureStage.allCases.map(\.rawValue))
    }

    // The screen-image caps of a note and of Ask are enforced on both sides: a client sending more than the server accepts would
    // fail every note with `screen_images_over_limit`; a server accepting more would not protect the AI budget.
    @Test func screenNoteBudgetMatchesServer() throws {
        let images: String = try String(contentsOf: serverDirectory().appending(path: "src/llm/images.ts"), encoding: .utf8)
        #expect(try serverNumber(source: images, name: "screenImageMaxCount") == screenNoteBudget.maxImages)
        #expect(try serverNumber(source: images, name: "screenImageMaxBytes") == screenNoteBudget.maxImageBytes)
        #expect(try serverNumber(source: images, name: "screenImageMaxTotalTokens") == screenNoteBudget.maxTotalTokens)
        let purposes: Substring = try #require(images.firstRange(of: "export const screenImagePurposes: readonly LLMPurpose[] = [").map { images[$0.upperBound...] })
        let listed: [String] = try #require(purposes.firstRange(of: "];").map { purposes[..<$0.lowerBound] }).matches(of: #/"([a-z_]+)"/#).map { String($0.output.1) }
        #expect(listed == [LLMPurpose.note.rawValue, LLMPurpose.noteOverview.rawValue, LLMPurpose.askAnswer.rawValue])
        // Ask has its own, lower caps on the server (`ask_answer`); the per-image byte cap is shared.
        #expect(try serverNumber(source: images, name: "askScreenImageMaxCount") == askScreenBudget.maxImages)
        #expect(try serverNumber(source: images, name: "askScreenImageMaxTotalTokens") == askScreenBudget.maxTotalTokens)
        #expect(askScreenBudget.maxImageBytes == screenNoteBudget.maxImageBytes)
    }
}

extension ServerParityTests {
    // Sync object kinds, envelope kinds, the blob marker and the limits are enforced on both sides: an unknown kind is
    // refused (`bad_request`), and a client cap above the server's would fail uploads the client thinks are fine.
    @Test func syncListsAndLimitsMatchServer() throws {
        let sync: String = try String(contentsOf: serverDirectory().appending(path: "src/sync.ts"), encoding: .utf8)
        #expect(try serverArray(source: sync, name: "syncObjectKinds") == SyncObjectKind.allCases.map(\.rawValue))
        #expect(try serverArray(source: sync, name: "syncEnvelopeKinds") == SyncEnvelopeKind.allCases.map(\.rawValue))
        #expect(try serverNumber(source: sync, name: "syncObjectMaxBytes") == SyncLimits.objectMaxBytes)
        #expect(try serverNumber(source: sync, name: "syncAccountMaxObjects") == SyncLimits.accountMaxObjects)
        #expect(try serverNumber(source: sync, name: "syncAccountMaxBytes") == SyncLimits.accountMaxBytes)
        #expect(try serverNumber(source: sync, name: "syncChangesMaxLimit") == SyncLimits.changesMaxLimit)
        #expect(try serverNumber(source: sync, name: "syncEnvelopeMaxChars") == SyncLimits.envelopeMaxChars)
        #expect(sync.contains("export const syncBlobMagic: string = \"\(syncBlobMagic)\";"))
    }

    // Note share limits and the blob marker: a client cap above the server's would fail uploads the client thinks fit,
    // and an expiry the server does not know is `bad_request`.
    @Test func shareLimitsMatchServer() throws {
        let shares: String = try String(contentsOf: serverDirectory().appending(path: "src/shares.ts"), encoding: .utf8)
        #expect(try serverNumber(source: shares, name: "shareMaxBytes") == noteShareMaxBytes)
        #expect(try serverNumber(source: shares, name: "shareMaxActivePerUser") == noteShareMaxActiveLinks)
        #expect(shares.contains("export const shareBlobMagic: string = \"\(noteShareMagic)\";"))
        let days: String = NoteShareExpiry.allCases.map { String($0.rawValue) }.joined(separator: ", ")
        #expect(shares.contains("export const shareExpiryDays: readonly number[] = [\(days)];"))
    }

    // Sor'un web araması ve çağrı sınırı iki tarafta aynı: istemci sunucunun kabul ettiğinden çok arama isterse her web
    // aramalı soru `invalid_body` alır; sunucunun Sor sınırı istemcininkinden küçükse istemci kesilme mesajını yanlış söyler.
    @Test func askWebSearchAndTokenCapMatchServer() throws {
        let webSearch: String = try String(contentsOf: serverDirectory().appending(path: "src/llm/webSearch.ts"), encoding: .utf8)
        #expect(try serverNumber(source: webSearch, name: "webSearchMaxUsesPerAnswer") == askWebSearchMaxUses)
        #expect(webSearch.contains("export const webSearchToolType = \"\(webSearchToolType)\" as const;"))
        let wrangler: String = try String(contentsOf: serverDirectory().appending(path: "wrangler.jsonc"), encoding: .utf8)
        let caps: [Int] = wrangler.matches(of: #/"LLM_ASK_MAX_TOKENS": "(\d+)"/#).compactMap { Int($0.output.1) }
        #expect(caps.count == 2 && caps.allSatisfy { $0 == hostedAskAnswerMaxTokens }, "\(caps)")
    }
}

/// Sunucu kaynağındaki `export const <ad>: number = <sayı>;` sabiti (`_` ayraçlarıyla yazılabilir).
private func serverNumber(source: String, name: String) throws -> Int {
    let start: Substring = try #require(source.firstRange(of: "export const \(name): number = ").map { source[$0.upperBound...] })
    let literal: Substring = try #require(start.firstRange(of: ";").map { start[..<$0.lowerBound] })
    return try #require(Int(literal.replacingOccurrences(of: "_", with: "")))
}

/// Sunucu kaynağındaki `export const <ad> = [ ... ] as const;` dizisinin dizgeleri (sırasıyla).
private func serverArray(source: String, name: String) throws -> [String] {
    let start: Substring = try #require(source.firstRange(of: "export const \(name) = [").map { source[$0.upperBound...] })
    let body: Substring = try #require(start.firstRange(of: "] as const;").map { start[..<$0.lowerBound] })
    return body.matches(of: #/"([A-Za-z_.-]+)"/#).map { String($0.output.1) }
}
