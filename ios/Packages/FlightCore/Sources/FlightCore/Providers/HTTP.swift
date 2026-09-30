import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so providers can be tested with canned responses.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    // dataTask + continuation instead of `data(for:)` so this also builds on
    // Linux Foundation, where the async URLSession API isn't guaranteed.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: ProviderError.transport(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ProviderError.transport("No HTTP response"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }
}

public enum ProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    case transport(String)
    case unauthorized
    /// 429. `retryAfter` in seconds when the server sent it.
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, body: String)
    case decoding(String)
    case missingCredentials(String)
    /// Our own monthly unit budget would be exceeded.
    case budgetExhausted

    public var description: String {
        switch self {
        case .transport(let m): return "Network error: \(m)"
        case .unauthorized: return "API key rejected (401/403). Check Secrets.xcconfig."
        case .rateLimited(let s): return "Rate limited" + (s.map { ", retry in \(Int($0))s" } ?? "")
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(200))"
        case .decoding(let m): return "Unexpected response format: \(m)"
        case .missingCredentials(let what): return "Missing credentials: \(what)"
        case .budgetExhausted: return "Monthly AeroDataBox budget reached; polling paused to keep a reserve."
        }
    }

    static func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw ProviderError.unauthorized
        case 429:
            let retry = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw ProviderError.rateLimited(retryAfter: retry)
        default:
            throw ProviderError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}

/// Parses the timestamp shapes AeroDataBox and OpenSky emit:
/// "2026-10-05 14:30Z", "2026-10-05 09:30-05:00", "2026-10-05T14:30:00Z", "...T14:30:00.123Z".
public enum TimestampParser {
    public static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), s.count >= 16 else { return nil }
        if s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        // Add seconds when the string is "yyyy-MM-ddTHH:mm" followed by a zone.
        let timeStart = s.index(s.startIndex, offsetBy: 11)
        let afterMinutes = s.index(timeStart, offsetBy: 5, limitedBy: s.endIndex) ?? s.endIndex
        if afterMinutes < s.endIndex, s[afterMinutes] != ":" {
            s.insert(contentsOf: ":00", at: afterMinutes)
        } else if afterMinutes == s.endIndex {
            s += ":00Z"
        }
        if let d = makeFormatter(fractional: false).date(from: s) { return d }
        return makeFormatter(fractional: true).date(from: s)
    }

    // ISO8601DateFormatter isn't documented as thread-safe, so build per call.
    // Polls happen a few times an hour; the cost is irrelevant.
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }
}
