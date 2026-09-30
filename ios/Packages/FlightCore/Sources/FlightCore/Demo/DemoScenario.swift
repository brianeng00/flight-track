import Foundation

/// A scripted flight (FT 101, AUS → ORD) that runs through every phase and alert.
/// Drives the app's "Simulate a flight" debug screen and the engine tests with the real engine:
/// only the providers are fake. Times are minutes relative to scheduled departure.
public struct DemoScenario: Sendable {
    public let scheduledDeparture: Date
    public var scheduledArrival: Date { scheduledDeparture.addingTimeInterval(2 * 3600 + 35 * 60) }

    static let aus = AirportRef(iata: "AUS", icao: "KAUS", name: "Austin-Bergstrom", city: "Austin",
                                timeZoneID: "America/Chicago", latitude: 30.1945, longitude: -97.6699)
    static let ord = AirportRef(iata: "ORD", icao: "KORD", name: "Chicago O'Hare", city: "Chicago",
                                timeZoneID: "America/Chicago", latitude: 41.9786, longitude: -87.9048)
    static let tail = "N37502"
    static let icao24 = "a4b3c2"

    public init(scheduledDeparture: Date) {
        self.scheduledDeparture = scheduledDeparture
    }

    public var query: FlightQuery {
        FlightQuery(number: "FT101", date: FlightDate.dayString(scheduledDeparture, in: Self.aus.timeZone),
                    departureAirportCode: "AUS", scheduledDeparture: scheduledDeparture)
    }

    private func t(_ minutes: Double) -> Date { scheduledDeparture.addingTimeInterval(minutes * 60) }

    /// The story, in order:
    ///  -180 on time, gate B12      -120 gate change B12 → B18     -90 delayed 25m
    ///   -10 boarding (dep now +25) +22 pushback                    +34 takeoff
    ///  +175 landed                 +183 at gate 32                  +200 bags on belt 5
    public func snapshot(at now: Date) -> FlightSnapshot {
        let m = now.timeIntervalSince(scheduledDeparture) / 60
        let delayed = m >= -90
        let depBest = delayed ? t(25) : t(0)
        let takeoff = t(34), landing = t(175), gateIn = t(183)
        let arrBest = delayed ? t(155 + 25) : t(155)

        var status: ProviderStatus = .expected
        if m >= -90 { status = .delayed }
        if m >= -10 { status = .boarding }
        if m >= 22 { status = .departed }
        if m >= 34 { status = .enRoute }
        if m >= 160 { status = .approaching }
        if m >= 175 { status = .arrived }

        let departure = Movement(
            airport: Self.aus,
            times: MovementTimes(scheduled: t(0), revised: m >= 22 ? t(22) : depBest, runway: m >= 34 ? takeoff : nil),
            terminal: "1", gate: m >= -120 ? "B18" : "B12", isLive: true)
        let arrival = Movement(
            airport: Self.ord,
            times: MovementTimes(scheduled: t(155), revised: m >= 175 ? gateIn : arrBest, runway: m >= 175 ? landing : nil),
            terminal: "1", gate: m >= -60 ? "C32" : nil, baggageBelt: m >= 200 ? "5" : nil, isLive: true)

        return FlightSnapshot(
            number: "FT 101", callSign: "FTK101", airlineName: "FlightTrack Air", airlineIATA: "FT", airlineICAO: "FTK",
            status: status, departure: departure, arrival: arrival,
            aircraft: AircraftInfo(registration: Self.tail, modeS: Self.icao24, model: "Boeing 737 MAX 8"),
            greatCircleNm: Geo.distanceNm(Self.aus.coordinate!, Self.ord.coordinate!),
            providerUpdatedAt: now, fetchedAt: now)
    }

    /// Where the demo plane is at `now` (nil on the ground).
    public func position(at now: Date) -> LivePosition? {
        let takeoff = t(34), landing = t(175)
        guard now > takeoff, now < landing else { return nil }
        let f = now.timeIntervalSince(takeoff) / landing.timeIntervalSince(takeoff)
        let path = Geo.greatCircle(Self.aus.coordinate!, Self.ord.coordinate!, count: 101)
        let i = min(Int(f * 100), 99)
        let here = path[i], next = path[i + 1]
        // Simple climb / cruise / descent profile.
        let altitude = f < 0.15 ? Int(f / 0.15 * 36000) : f > 0.85 ? Int((1 - f) / 0.15 * 36000) : 36000
        return LivePosition(latitude: here.latitude, longitude: here.longitude, altitudeFt: max(altitude, 800),
                            groundSpeedKt: f < 0.15 || f > 0.85 ? 330 : 470, trackDeg: Geo.bearingDeg(here, next),
                            verticalRateFpm: f < 0.15 ? 2200 : f > 0.85 ? -1800 : 0, onGround: false,
                            reportedAt: now, source: .openSky)
    }

    /// The inbound leg (FT 100 ORD → AUS). Runs late in the middle of the story.
    public func inbound(at now: Date) -> FlightSnapshot {
        let m = now.timeIntervalSince(scheduledDeparture) / 60
        let late = m >= -150 && m < -60
        let eta = late ? t(-5) : t(-50)
        return FlightSnapshot(
            number: "FT 100", airlineIATA: "FT", status: m >= -50 ? .arrived : .enRoute,
            departure: Movement(airport: Self.ord, times: MovementTimes(scheduled: t(-215))),
            arrival: Movement(airport: Self.aus, times: MovementTimes(scheduled: t(-50), revised: eta)),
            aircraft: AircraftInfo(registration: Self.tail, modeS: Self.icao24), fetchedAt: now)
    }
}

/// Serves `DemoScenario` through the real provider protocols, on a controllable clock.
public final class DemoProviders: FlightStatusProvider, PositionProvider, @unchecked Sendable {
    public let scenario: DemoScenario
    private let lock = NSLock()
    private var clock: Date
    public let unitsPerCall = 0 // demo never spends real budget

    public init(scenario: DemoScenario, start: Date) {
        self.scenario = scenario
        self.clock = start
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return clock
    }

    public func advance(to date: Date) {
        lock.lock(); clock = date; lock.unlock()
    }

    public func flights(number: String, date: String) async throws -> [FlightSnapshot] {
        [scenario.snapshot(at: now)]
    }

    public func flights(registration: String, date: String) async throws -> [FlightSnapshot] {
        [scenario.inbound(at: now), scenario.snapshot(at: now)]
    }

    public func position(icao24: String) async throws -> LivePosition? { scenario.position(at: now) }

    public func track(icao24: String) async throws -> [TrackPoint] { [] }
}
