import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Schedule, status, gates and baggage for a flight leg.
public protocol FlightStatusProvider: Sendable {
    /// All legs operating under `number` that depart or arrive on local date `date` ("yyyy-MM-dd").
    func flights(number: String, date: String) async throws -> [FlightSnapshot]
    /// All legs flown by tail number `registration` on local date `date`. Used for "Where's my plane".
    func flights(registration: String, date: String) async throws -> [FlightSnapshot]
    /// Units one call costs against the monthly plan (AeroDataBox flight status is TIER 2 = 2 units).
    var unitsPerCall: Int { get }
}

/// AeroDataBox is only sold through API marketplaces. Both expose the same paths.
public enum AeroDataBoxMarketplace: Sendable, Equatable {
    /// https://api.market, header `x-api-market-key` (the host in AeroDataBox's own OpenAPI spec).
    case apiMarket(key: String)
    /// https://rapidapi.com, headers `X-RapidAPI-Key` + `X-RapidAPI-Host`.
    case rapidAPI(key: String)

    var baseURL: URL {
        switch self {
        case .apiMarket: return URL(string: "https://prod.api.market/api/v1/aedbx/aerodatabox")!
        case .rapidAPI: return URL(string: "https://aerodatabox.p.rapidapi.com")!
        }
    }

    func authorize(_ request: inout URLRequest) {
        switch self {
        case .apiMarket(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-market-key")
        case .rapidAPI(let key):
            request.setValue(key, forHTTPHeaderField: "X-RapidAPI-Key")
            request.setValue("aerodatabox.p.rapidapi.com", forHTTPHeaderField: "X-RapidAPI-Host")
        }
    }
}

public struct AeroDataBoxClient: FlightStatusProvider {
    public let marketplace: AeroDataBoxMarketplace
    public let http: HTTPClient
    /// Ask for AeroDataBox's own position block. Off by default: OpenSky covers position for free.
    public var withLocation: Bool
    public let unitsPerCall = 2

    public init(marketplace: AeroDataBoxMarketplace, http: HTTPClient = URLSessionHTTPClient(), withLocation: Bool = false) {
        self.marketplace = marketplace
        self.http = http
        self.withLocation = withLocation
    }

    public func flights(number: String, date: String) async throws -> [FlightSnapshot] {
        try await fetch(searchBy: "number", param: FlightNumber.normalize(number), date: date)
    }

    public func flights(registration: String, date: String) async throws -> [FlightSnapshot] {
        try await fetch(searchBy: "reg", param: registration.uppercased(), date: date)
    }

    func makeRequest(searchBy: String, param: String, date: String) -> URLRequest {
        var components = URLComponents(
            url: marketplace.baseURL.appendingPathComponent("flights/\(searchBy)/\(param)/\(date)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "withAircraftImage", value: "false"),
            URLQueryItem(name: "withLocation", value: withLocation ? "true" : "false"),
            URLQueryItem(name: "dateLocalRole", value: "Both"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        marketplace.authorize(&request)
        return request
    }

    /// Raw response body for a flight-number lookup. Used by `flightcheck --raw` to record fixtures.
    public func rawFlights(number: String, date: String) async throws -> Data {
        try await rawFetch(searchBy: "number", param: FlightNumber.normalize(number), date: date)
    }

    private func fetch(searchBy: String, param: String, date: String) async throws -> [FlightSnapshot] {
        let data = try await rawFetch(searchBy: searchBy, param: param, date: date)
        if data.isEmpty { return [] }
        return try AeroDataBoxDecoder.decodeFlights(data, fetchedAt: Date())
    }

    private func rawFetch(searchBy: String, param: String, date: String) async throws -> Data {
        let (data, response) = try await http.send(makeRequest(searchBy: searchBy, param: param, date: date))
        // 204 = "no flights found" per the spec.
        if response.statusCode == 204 { return Data() }
        try ProviderError.check(response, data: data)
        return data
    }
}

/// Maps AeroDataBox `FlightContract` JSON (OpenAPI v1.14) into our models.
public enum AeroDataBoxDecoder {
    public static func decodeFlights(_ data: Data, fetchedAt: Date) throws -> [FlightSnapshot] {
        let dtos: [ADBFlight]
        do {
            dtos = try JSONDecoder().decode([ADBFlight].self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
        return dtos.map { $0.toSnapshot(fetchedAt: fetchedAt) }
    }
}

// MARK: - Wire DTOs (field names straight from the AeroDataBox OpenAPI spec)

struct ADBFlight: Decodable {
    var greatCircleDistance: ADBDistance?
    var departure: ADBMovement
    var arrival: ADBMovement
    var lastUpdatedUtc: String?
    var number: String
    var callSign: String?
    var status: ProviderStatus?
    var isCargo: Bool?
    var aircraft: ADBAircraft?
    var airline: ADBAirline?
    var location: ADBLocation?

    func toSnapshot(fetchedAt: Date) -> FlightSnapshot {
        FlightSnapshot(
            number: FlightNumber.display(number),
            callSign: callSign,
            airlineName: airline?.name,
            airlineIATA: airline?.iata,
            airlineICAO: airline?.icao,
            status: status ?? .unknown,
            departure: departure.toMovement(),
            arrival: arrival.toMovement(),
            aircraft: aircraft.map { AircraftInfo(registration: $0.reg, modeS: $0.modeS, model: $0.model) },
            position: location?.toPosition(),
            greatCircleNm: greatCircleDistance?.nm,
            isCargo: isCargo ?? false,
            providerUpdatedAt: TimestampParser.parse(lastUpdatedUtc),
            fetchedAt: fetchedAt
        )
    }
}

struct ADBMovement: Decodable {
    var airport: ADBAirport?
    var scheduledTime: ADBDateTime?
    var revisedTime: ADBDateTime?
    var predictedTime: ADBDateTime?
    var runwayTime: ADBDateTime?
    var terminal: String?
    var checkInDesk: String?
    var gate: String?
    var baggageBelt: String?
    var runway: String?
    var quality: [String]?

    func toMovement() -> Movement {
        Movement(
            airport: airport?.toRef() ?? AirportRef(iata: nil, icao: nil, name: "Unknown airport"),
            times: MovementTimes(
                scheduled: TimestampParser.parse(scheduledTime?.utc),
                revised: TimestampParser.parse(revisedTime?.utc),
                predicted: TimestampParser.parse(predictedTime?.utc),
                runway: TimestampParser.parse(runwayTime?.utc)
            ),
            terminal: terminal.nonEmpty,
            gate: gate.nonEmpty,
            checkInDesk: checkInDesk.nonEmpty,
            baggageBelt: baggageBelt.nonEmpty,
            runway: runway.nonEmpty,
            isLive: quality?.contains("Live") ?? false
        )
    }
}

struct ADBAirport: Decodable {
    var icao: String?
    var iata: String?
    var name: String?
    var shortName: String?
    var municipalityName: String?
    var location: ADBCoordinates?
    var timeZone: String?

    func toRef() -> AirportRef {
        AirportRef(
            iata: iata, icao: icao, name: shortName ?? name ?? iata ?? icao ?? "Unknown airport",
            city: municipalityName, timeZoneID: timeZone, latitude: location?.lat, longitude: location?.lon
        )
    }
}

struct ADBCoordinates: Decodable { var lat: Double; var lon: Double }
struct ADBDateTime: Decodable { var utc: String?; var local: String? }
struct ADBDistance: Decodable { var meter: Double?; var nm: Double?; var feet: Double? }
struct ADBSpeed: Decodable { var kt: Double? }
struct ADBAzimuth: Decodable { var deg: Double? }
struct ADBAircraft: Decodable { var reg: String?; var modeS: String?; var model: String? }
struct ADBAirline: Decodable { var name: String?; var iata: String?; var icao: String? }

struct ADBLocation: Decodable {
    var pressureAltitude: ADBDistance?
    var altitude: ADBDistance?
    var groundSpeed: ADBSpeed?
    var trueTrack: ADBAzimuth?
    var vsiFpm: Int?
    var reportedAtUtc: String?
    var lat: Double
    var lon: Double

    func toPosition() -> LivePosition? {
        guard let reported = TimestampParser.parse(reportedAtUtc) else { return nil }
        let feet = (pressureAltitude?.feet ?? altitude?.feet).map { Int($0.rounded()) }
        return LivePosition(
            latitude: lat, longitude: lon, altitudeFt: feet,
            groundSpeedKt: groundSpeed?.kt.map { Int($0.rounded()) }, trackDeg: trueTrack?.deg,
            verticalRateFpm: vsiFpm, onGround: (feet ?? 0) < 100 && (groundSpeed?.kt ?? 0) < 50,
            reportedAt: reported, source: .aeroDataBox
        )
    }
}

extension Optional where Wrapped == String {
    /// Treats "" and whitespace-only strings as missing.
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
