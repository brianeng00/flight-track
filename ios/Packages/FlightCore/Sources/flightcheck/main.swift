import FlightCore
import Foundation

// flightcheck: M1 data spike. Answers "does AeroDataBox (free) actually give us what the app needs?"
//
//   swift run flightcheck UA123 2026-10-05          live lookup (needs a key, see below)
//   swift run flightcheck UA123 2026-10-05 --raw    also save the raw JSON as a test fixture
//   swift run flightcheck --demo                    run the engine over the scripted demo flight, no keys
//
// Keys come from environment variables so nothing secret touches the repo:
//   ADB_APIMARKET_KEY=...  (api.market)   or   ADB_RAPIDAPI_KEY=...  (RapidAPI)
//   OPENSKY_CLIENT_ID=... OPENSKY_CLIENT_SECRET=...  (optional; same values as the web app's .env)

let env = ProcessInfo.processInfo.environment
let args = Array(CommandLine.arguments.dropFirst())

func line(_ s: String = "") { print(s) }
func mark(_ ok: Bool) -> String { ok ? "✅" : "❌" }

if args.contains("--demo") {
    await runDemo()
    exit(0)
}

let positional = args.filter { !$0.hasPrefix("--") }
guard positional.count == 2 else {
    line("usage: flightcheck <FLIGHT> <yyyy-MM-dd> [--raw]   |   flightcheck --demo")
    exit(2)
}
let (number, date) = (positional[0], positional[1])

let marketplace: AeroDataBoxMarketplace
if let key = env["ADB_APIMARKET_KEY"], !key.isEmpty {
    marketplace = .apiMarket(key: key)
} else if let key = env["ADB_RAPIDAPI_KEY"], !key.isEmpty {
    marketplace = .rapidAPI(key: key)
} else {
    line("Set ADB_APIMARKET_KEY or ADB_RAPIDAPI_KEY first.")
    exit(2)
}
let adb = AeroDataBoxClient(marketplace: marketplace)

do {
    if args.contains("--raw") {
        let raw = try await adb.rawFlights(number: number, date: date)
        let file = "adb_\(FlightNumber.normalize(number))_\(date).json"
        try raw.write(to: URL(fileURLWithPath: file))
        line("Saved raw response to \(file) (\(raw.count) bytes). Flight status only, no personal data, safe to commit as a fixture.")
    }
    let legs = try await adb.flights(number: number, date: date)
    line("\(legs.count) leg(s) for \(FlightNumber.display(number)) on \(date) (cost: \(adb.unitsPerCall) units)")
    for leg in legs { await report(leg) }
} catch {
    line("Lookup failed: \(error)")
    exit(1)
}

func report(_ s: FlightSnapshot) async {
    let d = s.departure, a = s.arrival
    let dz = d.airport.timeZone, az = a.airport.timeZone
    line()
    line("── \(s.number)  \(d.airport.code) → \(a.airport.code)  status: \(s.status.rawValue)  phase: \(PhaseResolver.resolve(s, position: nil, now: Date()).rawValue)")
    line("   airline: \(s.airlineName ?? "?")   aircraft: \(s.aircraft?.model ?? "?")  reg \(s.aircraft?.registration ?? "?")  modeS \(s.aircraft?.modeS ?? "?")")
    line("   DEP \(d.airport.name)  sched \(FlightFormat.localTime(d.times.scheduled, timeZone: dz))  revised \(FlightFormat.localTime(d.times.revised, timeZone: dz))  runway \(FlightFormat.localTime(d.times.runway, timeZone: dz))  \(FlightFormat.gateLine(d))  live=\(d.isLive)")
    line("   ARR \(a.airport.name)  sched \(FlightFormat.localTime(a.times.scheduled, timeZone: az))  revised \(FlightFormat.localTime(a.times.revised, timeZone: az))  runway \(FlightFormat.localTime(a.times.runway, timeZone: az))  \(FlightFormat.gateLine(a))  belt \(a.baggageBelt ?? "-")  live=\(a.isLive)")
    line("   Coverage check (what the app needs):")
    line("     \(mark(d.times.scheduled != nil)) scheduled departure      \(mark(a.times.scheduled != nil)) scheduled arrival")
    line("     \(mark(d.times.revised != nil)) revised departure        \(mark(a.times.revised != nil)) revised arrival")
    line("     \(mark(d.gate != nil)) departure gate           \(mark(a.gate != nil)) arrival gate")
    line("     \(mark(d.terminal != nil)) departure terminal       \(mark(a.baggageBelt != nil)) baggage belt (only near arrival)")
    line("     \(mark(s.aircraft?.modeS != nil)) Mode-S (needed for OpenSky)  \(mark(s.aircraft?.registration != nil)) tail number (needed for inbound)")
    line("     \(mark(d.isLive || a.isLive)) live quality marker       \(mark(d.airport.hasCoordinate && a.airport.hasCoordinate)) airport coordinates")

    if let icao = s.aircraft?.modeS {
        let creds = env["OPENSKY_CLIENT_ID"].flatMap { id in
            env["OPENSKY_CLIENT_SECRET"].map { OpenSkyClient.Credentials(clientID: id, clientSecret: $0) }
        }
        let sky = OpenSkyClient(credentials: creds)
        do {
            if let p = try await sky.position(icao24: icao) {
                line("   OpenSky: \(p.latitude), \(p.longitude)  \(p.altitudeFt ?? 0) ft  \(p.groundSpeedKt ?? 0) kt  onGround=\(p.onGround)")
            } else {
                line("   OpenSky: no current position for \(icao) (normal unless the plane is flying now)")
            }
        } catch {
            line("   OpenSky: \(error)")
        }
    }
}

func runDemo() async {
    let departure = Date().addingTimeInterval(3 * 3600)
    let scenario = DemoScenario(scheduledDeparture: departure)
    let start = departure.addingTimeInterval(-3 * 3600)
    let providers = DemoProviders(scenario: scenario, start: start)
    let engine = FlightEngine(status: providers, position: providers)
    var budget = UnitBudget(periodStart: start)
    var flight = TrackedFlight(query: scenario.query, snapshot: scenario.snapshot(at: start), now: start)
    line("Demo: FT 101 AUS → ORD, one engine pass per simulated 2 minutes")
    var t = start
    while t < departure.addingTimeInterval(4 * 3600) {
        providers.advance(to: t)
        let result = await engine.refresh(flight, budget: &budget, now: t, force: true)
        flight = result.flight
        let clock = FlightFormat.localTime(t, timeZone: TimeZone(identifier: "America/Chicago")!)
        for event in result.newEvents where event.notifies {
            let alert = AlertFormatter.content(for: event, flight: flight)
            line("\(clock)  [\(flight.phase.rawValue)]  \(alert.title): \(alert.body)")
        }
        if PollScheduler.trackingEnds(for: flight, now: t) {
            line("\(clock)  tracking ends")
            break
        }
        t = t.addingTimeInterval(120)
    }
}
