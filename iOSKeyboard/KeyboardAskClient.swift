import Foundation
import KeyboardCore
import os

/// Only the failure kind and HTTP status are logged; the question and the answer never are.
private let askClientLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "KeyboardAskClient")

/// Asks Gistsmith's server directly (`POST /v1/keyboard/ask` with the keyboard token): one attempt, and one more after a
/// short pause only when the request never reached the server (`keyboardAskShouldRetry`). Returns the answer's text, or
/// the last attempt's failure.
func keyboardAskSend(token: KeyboardAskToken, body: KeyboardAskRequestBody) async -> Result<String, KeyboardAskAttemptFailure> {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload: Data
    do {
        payload = try encoder.encode(body)
    } catch {
        askClientLogger.error("Keyboard question could not be encoded: \(String(describing: type(of: error)), privacy: .public)")
        return .failure(.status(0))
    }
    var request: URLRequest = URLRequest(url: token.baseURL.appending(path: "v1/keyboard/ask"), timeoutInterval: keyboardAskDirectTimeout)
    request.httpMethod = "POST"
    request.httpBody = payload
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("Bearer \(token.token)", forHTTPHeaderField: "authorization")
    let configuration: URLSessionConfiguration = .ephemeral
    configuration.timeoutIntervalForRequest = keyboardAskDirectTimeout
    let session: URLSession = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    var last: KeyboardAskAttemptFailure = .notConnected
    for attempt in 1...2 {
        let outcome: Result<String, KeyboardAskAttemptFailure> = await keyboardAskAttempt(session: session, request: request)
        switch outcome {
        case .success:
            return outcome
        case .failure(let failure):
            last = failure
            askClientLogger.warning("Keyboard question attempt failed, attempt: \(attempt, privacy: .public), failure: \(String(describing: failure), privacy: .public)")
            guard attempt == 1, keyboardAskShouldRetry(failure: failure), !Task.isCancelled else {
                return .failure(failure)
            }
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                return .failure(failure)
            }
        }
    }
    return .failure(last)
}

private func keyboardAskAttempt(session: URLSession, request: URLRequest) async -> Result<String, KeyboardAskAttemptFailure> {
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch let error as URLError {
        askClientLogger.warning("Keyboard question request failed, URL error code: \(error.code.rawValue, privacy: .public)")
        return .failure(keyboardAskNeverSent.contains(error.code) ? .notConnected : .noResponse)
    } catch {
        askClientLogger.warning("Keyboard question request failed, error type: \(String(describing: type(of: error)), privacy: .public)")
        return .failure(.noResponse)
    }
    guard let http = response as? HTTPURLResponse else {
        return .failure(.noResponse)
    }
    guard (200..<300).contains(http.statusCode) else {
        return .failure(.status(http.statusCode))
    }
    do {
        return .success(try JSONDecoder().decode(KeyboardAskResponseBody.self, from: data).answer.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        return .failure(.unreadableAnswer)
    }
}

/// URL errors that mean the request never reached the server, so retrying cannot ask (and charge) twice.
private let keyboardAskNeverSent: Set<URLError.Code> = [
    .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
]
