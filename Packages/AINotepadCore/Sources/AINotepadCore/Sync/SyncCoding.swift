import Foundation

/// A sync payload could not be read.
public enum SyncPayloadError: Error, Sendable, Equatable {
    /// The compressed bytes are not valid zlib data; `reason` is the system's message.
    case notCompressed(byteCount: Int, reason: String)
    /// The JSON does not match the expected payload; `reason` is the decoder's message (no content).
    case malformedJSON(reason: String)
    /// Written by a newer app (`schema` above `syncPayloadSchema`): update this app to read it.
    case unsupportedSchema(found: Int, supported: Int)
}

/// Canonical JSON of a payload: sorted keys, no escaped slashes, dates as the default `Double` seconds since 2001
/// (lossless round trip on Apple platforms). The same value always gives the same bytes, so unchanged objects are not
/// re-uploaded and merges compare by value. Pure function.
public func canonicalSyncJSON<Value: Encodable>(value: Value) throws -> Data {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

/// A payload ready for encryption: canonical JSON compressed with zlib (text compresses ~6x; doc §1.2). Compression
/// happens before encryption because ciphertext does not compress. Pure function.
public func encodeSyncPayload<Value: Encodable>(value: Value) throws -> Data {
    let json: Data = try canonicalSyncJSON(value: value)
    return try (json as NSData).compressed(using: .zlib) as Data
}

/// Schema header every payload carries.
private struct SchemaHeader: Decodable {
    let schema: Int
}

/// Reads a decrypted payload: decompresses, checks the schema (a newer schema is `unsupportedSchema`, never read
/// partially), decodes. Pure function.
public func decodeSyncPayload<Value: Decodable>(type: Value.Type, data: Data) throws -> Value {
    let json: Data
    do {
        json = try (data as NSData).decompressed(using: .zlib) as Data
    } catch let error as NSError {
        throw SyncPayloadError.notCompressed(byteCount: data.count, reason: "\(error.domain) \(error.code)")
    }
    let decoder: JSONDecoder = JSONDecoder()
    do {
        let header: SchemaHeader = try decoder.decode(SchemaHeader.self, from: json)
        guard header.schema <= syncPayloadSchema else {
            throw SyncPayloadError.unsupportedSchema(found: header.schema, supported: syncPayloadSchema)
        }
        return try decoder.decode(type, from: json)
    } catch let error as SyncPayloadError {
        throw error
    } catch let error as DecodingError {
        throw SyncPayloadError.malformedJSON(reason: decodingFailure(error: error))
    }
}

/// Decoder failure without values: the coding path and the kind of problem. Pure function.
private func decodingFailure(error: DecodingError) -> String {
    let path: ([any CodingKey]) -> String = { (keys: [any CodingKey]) -> String in keys.map(\.stringValue).joined(separator: ".") }
    switch error {
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
        return "\(path(context.codingPath)): \(context.debugDescription)"
    @unknown default:
        return "unknown decoding error"
    }
}
