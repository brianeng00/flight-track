import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live ADS-B position and flown track for one airframe.
public protocol PositionProvider: Sendable {
    func position(icao24: String) async throws -> LivePosition?
    func track(icao24: String) async throws -> [TrackPoint]
}

/// Swift port of the web app's OpenSky usage (`src/hooks/useOpenSky.ts`, `src/lib/opensky.ts`):
/// OAuth2 client credentials, `/states/all` filtered by `icao24`, and `/tracks/all`.
public actor OpenSkyClient: PositionProvider {
    public struct Credentials: Sendable, Equatable {
        public var clientID: String
        public var clientSecret: String
        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    static let tokenURL = URL(string: "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token")!
    static let apiBase = URL(string: "https://opensky-network.org/api")!

    private let credentials: Credentials?
    private let http: HTTPClient
    private var token: (value: String, expiresAt: Date)?

    /// `credentials` nil = anonymous access (lower daily credit limit, same as the web app without .env).
    public init(credentials: Credentials?, http: HTTPClient = URLSessionHTTPClient()) {
        self.credentials = credentials
        self.http = http
    }

    public func position(icao24: String) async throws -> LivePosition? {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent("states/all"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "icao24", value: icao24.lowercased())]
        let data = try await get(components.url!)
        return try OpenSkyDecoder.decodeStates(data).first
    }

    public func track(icao24: String) async throws -> [TrackPoint] {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent("tracks/all"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "icao24", value: icao24.lowercased()),
            URLQueryItem(name: "time", value: "0"),
        ]
        do {
            return try OpenSkyDecoder.decodeTrack(try await get(components.url!))
        } catch ProviderError.http(status: 404, _) {
            // No track for this airframe right now. Not an error for our purposes.
            return []
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let bearer = try await bearerToken() {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await http.send(request)
        try ProviderError.check(response, data: data)
        return data
    }

    private func bearerToken() async throws -> String? {
        guard let credentials else { return nil }
        // Same refresh margin as the web app: renew a minute before expiry.
        if let token, token.expiresAt > Date().addingTimeInterval(60) { return token.value }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "client_credentials",
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
        ])
        let (data, response) = try await http.send(request)
        try ProviderError.check(response, data: data)
        struct TokenResponse: Decodable { var access_token: String; var expires_in: Double }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ProviderError.decoding("OpenSky token response")
        }
        token = (decoded.access_token, Date().addingTimeInterval(decoded.expires_in))
        return decoded.access_token
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

/// OpenSky returns positional arrays of mixed types. Decoded through `JSONValue` rather than
/// JSONSerialization, which on Apple platforms can hand back 0/1 numbers as booleans.
/// Index map matches `RawStateVector` in the web app's `src/types.ts`.
public enum OpenSkyDecoder {
    public static func decodeStates(_ data: Data) throws -> [LivePosition] {
        guard case .object(let root) = try decodeRoot(data) else {
            throw ProviderError.decoding("OpenSky states root")
        }
        guard case .array(let states)? = root["states"] else { return [] } // null when nothing matches
        return states.compactMap { row in
            guard case .array(let fields) = row else { return nil }
            return parseState(fields)
        }
    }

    static func parseState(_ s: [JSONValue]) -> LivePosition? {
        guard s.count >= 12, let lon = s[5].number, let lat = s[6].number else { return nil }
        let reported = s[3].number ?? s[4].number ?? Date().timeIntervalSince1970
        return LivePosition(
            latitude: lat, longitude: lon,
            altitudeFt: s[7].number.map { Units.metersToFeet($0) },
            groundSpeedKt: s[9].number.map { Units.msToKnots($0) },
            trackDeg: s[10].number,
            verticalRateFpm: s[11].number.map { Units.msToFeetPerMinute($0) },
            onGround: s[8].bool ?? false,
            reportedAt: Date(timeIntervalSince1970: reported),
            source: .openSky
        )
    }

    /// `/tracks/all` path rows: [time, lat, lon, baro_altitude_m, true_track, on_ground].
    public static func decodeTrack(_ data: Data) throws -> [TrackPoint] {
        guard case .object(let root) = try decodeRoot(data) else {
            throw ProviderError.decoding("OpenSky track root")
        }
        guard case .array(let path)? = root["path"] else { return [] }
        return path.compactMap { row in
            guard case .array(let r) = row, r.count >= 6,
                  let t = r[0].number, let lat = r[1].number, let lon = r[2].number else { return nil }
            return TrackPoint(
                time: Date(timeIntervalSince1970: t), latitude: lat, longitude: lon,
                altitudeFt: r[3].number.map { Units.metersToFeet($0) },
                trackDeg: r[4].number, onGround: r[5].bool ?? false
            )
        }
    }

    private static func decodeRoot(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw ProviderError.decoding(String(describing: error)) }
    }
}

/// Just enough of a JSON tree for positional arrays.
enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        // Bool before Double: JSONDecoder only decodes Bool from literal true/false.
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var number: Double? { if case .number(let d) = self { return d }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}
