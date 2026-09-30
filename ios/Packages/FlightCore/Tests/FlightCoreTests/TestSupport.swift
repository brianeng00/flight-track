import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FlightCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }
}

/// Canned HTTP responses keyed by a closure; records every request for assertions.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> (Int, Data, [String: String])

    init(respond: @escaping @Sendable (URLRequest) -> (Int, Data, [String: String])) {
        self.respond = respond
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); _requests.append(request); lock.unlock()
        let (status, body, headers) = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }
}

/// Fixed-answer status provider for engine tests.
final class ScriptedStatus: FlightStatusProvider, @unchecked Sendable {
    var legs: [FlightSnapshot]
    var tailLegs: [FlightSnapshot] = []
    var error: Error?
    private(set) var numberCalls = 0
    private(set) var registrationCalls = 0
    let unitsPerCall = 2

    init(_ legs: [FlightSnapshot]) { self.legs = legs }

    func flights(number: String, date: String) async throws -> [FlightSnapshot] {
        numberCalls += 1
        if let error { throw error }
        return legs
    }

    func flights(registration: String, date: String) async throws -> [FlightSnapshot] {
        registrationCalls += 1
        return tailLegs
    }
}

func utc(_ s: String) -> Date { TimestampParser.parse(s)! }

let chicago = TimeZone(identifier: "America/Chicago")!

/// A plain AUS → ORD leg departing at `departure`, arriving 2h35m later.
func makeSnapshot(
    departure: Date, status: ProviderStatus = .expected, depRevised: Date? = nil, depRunway: Date? = nil,
    arrRevised: Date? = nil, arrRunway: Date? = nil, depGate: String? = "B12", arrGate: String? = nil,
    belt: String? = nil, reg: String? = "N37502", modeS: String? = "a4b3c2", fetchedAt: Date? = nil
) -> FlightSnapshot {
    let aus = AirportRef(iata: "AUS", icao: "KAUS", name: "Austin-Bergstrom", city: "Austin",
                         timeZoneID: "America/Chicago", latitude: 30.1945, longitude: -97.6699)
    let ord = AirportRef(iata: "ORD", icao: "KORD", name: "Chicago O'Hare", city: "Chicago",
                         timeZoneID: "America/Chicago", latitude: 41.9786, longitude: -87.9048)
    return FlightSnapshot(
        number: "UA 1234", airlineName: "United", airlineIATA: "UA", status: status,
        departure: Movement(airport: aus, times: MovementTimes(scheduled: departure, revised: depRevised, runway: depRunway),
                            terminal: "1", gate: depGate, isLive: true),
        arrival: Movement(airport: ord, times: MovementTimes(scheduled: departure.addingTimeInterval(155 * 60),
                                                             revised: arrRevised, runway: arrRunway),
                          terminal: "1", gate: arrGate, baggageBelt: belt, isLive: true),
        aircraft: AircraftInfo(registration: reg, modeS: modeS, model: "Boeing 737 MAX 8"),
        fetchedAt: fetchedAt ?? departure)
}
