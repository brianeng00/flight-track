import Foundation

/// An airport as far as a single flight leg is concerned.
public struct AirportRef: Codable, Hashable, Sendable {
    public var iata: String?
    public var icao: String?
    public var name: String
    public var city: String?
    /// Olson time zone, e.g. "America/Chicago". Used for every local time we display.
    public var timeZoneID: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        iata: String?, icao: String?, name: String, city: String? = nil,
        timeZoneID: String? = nil, latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.iata = iata
        self.icao = icao
        self.name = name
        self.city = city
        self.timeZoneID = timeZoneID
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Short code for compact UI: IATA when known, else ICAO, else "???".
    public var code: String { iata ?? icao ?? "???" }

    public var timeZone: TimeZone { timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current }

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }

    /// True when two refs point at the same airport (codes can be missing on either side).
    public func isSameAirport(as other: AirportRef) -> Bool {
        if let a = icao, let b = other.icao { return a.caseInsensitiveCompare(b) == .orderedSame }
        if let a = iata, let b = other.iata { return a.caseInsensitiveCompare(b) == .orderedSame }
        return false
    }
}

/// The four clocks AeroDataBox reports for one end of a flight.
public struct MovementTimes: Codable, Hashable, Sendable {
    /// Published schedule (gate departure / gate arrival).
    public var scheduled: Date?
    /// Airline revised time: an estimate before it happens, the actual time after.
    public var revised: Date?
    /// AeroDataBox's own prediction, when it has one.
    public var predicted: Date?
    /// Actual (or estimated) takeoff / landing time on the runway.
    public var runway: Date?

    public init(scheduled: Date? = nil, revised: Date? = nil, predicted: Date? = nil, runway: Date? = nil) {
        self.scheduled = scheduled
        self.revised = revised
        self.predicted = predicted
        self.runway = runway
    }

    /// Best gate time we know: airline revised, then prediction, then schedule.
    public var bestGate: Date? { revised ?? predicted ?? scheduled }
}

/// One end (departure or arrival) of a flight leg.
public struct Movement: Codable, Hashable, Sendable {
    public var airport: AirportRef
    public var times: MovementTimes
    public var terminal: String?
    public var gate: String?
    public var checkInDesk: String?
    public var baggageBelt: String?
    public var runway: String?
    /// True when the provider marks this data as live (not just schedule).
    public var isLive: Bool

    public init(
        airport: AirportRef, times: MovementTimes, terminal: String? = nil, gate: String? = nil,
        checkInDesk: String? = nil, baggageBelt: String? = nil, runway: String? = nil, isLive: Bool = false
    ) {
        self.airport = airport
        self.times = times
        self.terminal = terminal
        self.gate = gate
        self.checkInDesk = checkInDesk
        self.baggageBelt = baggageBelt
        self.runway = runway
        self.isLive = isLive
    }

    /// Minutes between schedule and best known gate time. Positive = late.
    public var delayMinutes: Int? {
        guard let scheduled = times.scheduled, let best = times.bestGate else { return nil }
        return Int((best.timeIntervalSince(scheduled) / 60).rounded())
    }
}

/// Mirrors AeroDataBox `FlightStatus`. Unknown strings decode as `.unknown`.
public enum ProviderStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case unknown = "Unknown"
    case expected = "Expected"
    case enRoute = "EnRoute"
    case checkIn = "CheckIn"
    case boarding = "Boarding"
    case gateClosed = "GateClosed"
    case departed = "Departed"
    case delayed = "Delayed"
    case approaching = "Approaching"
    case arrived = "Arrived"
    case canceled = "Canceled"
    case diverted = "Diverted"
    case canceledUncertain = "CanceledUncertain"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderStatus(rawValue: raw) ?? .unknown
    }
}

public struct AircraftInfo: Codable, Hashable, Sendable {
    /// Tail number, e.g. "N12345".
    public var registration: String?
    /// ICAO 24-bit transponder address, lowercase hex (OpenSky's `icao24`).
    public var modeS: String?
    public var model: String?

    public init(registration: String? = nil, modeS: String? = nil, model: String? = nil) {
        self.registration = registration
        self.modeS = modeS?.lowercased()
        self.model = model
    }
}

public enum PositionSource: String, Codable, Hashable, Sendable {
    case aeroDataBox
    case openSky
    /// The phone's own GPS (you are on the plane).
    case device
    /// Projected forward from the last real fix.
    case deadReckoned
}

public struct LivePosition: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitudeFt: Int?
    public var groundSpeedKt: Int?
    public var trackDeg: Double?
    public var verticalRateFpm: Int?
    public var onGround: Bool
    public var reportedAt: Date
    public var source: PositionSource

    public init(
        latitude: Double, longitude: Double, altitudeFt: Int? = nil, groundSpeedKt: Int? = nil,
        trackDeg: Double? = nil, verticalRateFpm: Int? = nil, onGround: Bool = false,
        reportedAt: Date, source: PositionSource
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeFt = altitudeFt
        self.groundSpeedKt = groundSpeedKt
        self.trackDeg = trackDeg
        self.verticalRateFpm = verticalRateFpm
        self.onGround = onGround
        self.reportedAt = reportedAt
        self.source = source
    }

    /// Airborne by the same rule as the web app's `deriveStatus`: not on ground and 500 ft or higher.
    public var isAirborne: Bool { !onGround && (altitudeFt ?? 0) >= 500 }
}

/// One point of a flown track (OpenSky `/tracks/all` path element).
public struct TrackPoint: Codable, Hashable, Sendable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    public var altitudeFt: Int?
    public var trackDeg: Double?
    public var onGround: Bool

    public init(time: Date, latitude: Double, longitude: Double, altitudeFt: Int?, trackDeg: Double?, onGround: Bool) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeFt = altitudeFt
        self.trackDeg = trackDeg
        self.onGround = onGround
    }
}

/// Everything one status poll told us about one flight leg.
public struct FlightSnapshot: Codable, Hashable, Sendable {
    /// Display flight number, e.g. "UA 123".
    public var number: String
    public var callSign: String?
    public var airlineName: String?
    public var airlineIATA: String?
    public var airlineICAO: String?
    public var status: ProviderStatus
    public var departure: Movement
    public var arrival: Movement
    public var aircraft: AircraftInfo?
    public var position: LivePosition?
    public var greatCircleNm: Double?
    public var isCargo: Bool
    public var providerUpdatedAt: Date?
    public var fetchedAt: Date

    public init(
        number: String, callSign: String? = nil, airlineName: String? = nil, airlineIATA: String? = nil,
        airlineICAO: String? = nil, status: ProviderStatus, departure: Movement, arrival: Movement,
        aircraft: AircraftInfo? = nil, position: LivePosition? = nil, greatCircleNm: Double? = nil,
        isCargo: Bool = false, providerUpdatedAt: Date? = nil, fetchedAt: Date
    ) {
        self.number = number
        self.callSign = callSign
        self.airlineName = airlineName
        self.airlineIATA = airlineIATA
        self.airlineICAO = airlineICAO
        self.status = status
        self.departure = departure
        self.arrival = arrival
        self.aircraft = aircraft
        self.position = position
        self.greatCircleNm = greatCircleNm
        self.isCargo = isCargo
        self.providerUpdatedAt = providerUpdatedAt
        self.fetchedAt = fetchedAt
    }

    /// Stable identity for "the same leg" across polls: flight number + departure airport + scheduled day.
    public var legKey: String {
        let day = departure.times.scheduled.map { FlightDate.utcDayString($0) } ?? "?"
        return "\(FlightNumber.normalize(number))|\(departure.airport.code)|\(day)"
    }
}

/// What the person typed, plus which leg they picked when a number has several.
public struct FlightQuery: Codable, Hashable, Sendable {
    /// Normalized flight number, e.g. "UA123".
    public var number: String
    /// Local departure date, "yyyy-MM-dd".
    public var date: String
    /// Set once a leg is chosen, so later polls return the same leg.
    public var departureAirportCode: String?
    public var scheduledDeparture: Date?

    public init(number: String, date: String, departureAirportCode: String? = nil, scheduledDeparture: Date? = nil) {
        self.number = FlightNumber.normalize(number)
        self.date = date
        self.departureAirportCode = departureAirportCode
        self.scheduledDeparture = scheduledDeparture
    }

    /// Picks the leg this query refers to from a provider result list.
    public func pickLeg(from legs: [FlightSnapshot]) -> FlightSnapshot? {
        let candidates = legs.filter { !$0.isCargo || legs.allSatisfy(\.isCargo) }
        guard let code = departureAirportCode else {
            return candidates.count == 1 ? candidates.first : nil
        }
        let sameAirport = candidates.filter {
            $0.departure.airport.iata?.caseInsensitiveCompare(code) == .orderedSame
                || $0.departure.airport.icao?.caseInsensitiveCompare(code) == .orderedSame
        }
        guard let target = scheduledDeparture else { return sameAirport.first }
        return sameAirport.min { a, b in
            abs((a.departure.times.scheduled ?? .distantPast).timeIntervalSince(target))
                < abs((b.departure.times.scheduled ?? .distantPast).timeIntervalSince(target))
        }
    }
}

public enum FlightNumber {
    /// "ua 123" / "UA0123" / " UA123 " -> "UA123". Leading zeros in the numeric part are dropped.
    public static func normalize(_ raw: String) -> String {
        let compact = raw.uppercased().filter { !$0.isWhitespace }
        guard let split = splitIndex(compact) else { return compact }
        let prefix = compact[..<split]
        let digits = compact[split...]
        let trimmed = digits.drop { $0 == "0" }
        return String(prefix) + (trimmed.isEmpty ? "0" : String(trimmed))
    }

    /// "UA123" -> "UA 123" for display.
    public static func display(_ raw: String) -> String {
        let n = normalize(raw)
        guard let split = splitIndex(n) else { return n }
        return "\(n[..<split]) \(n[split...])"
    }

    /// Airline designators are 2 to 3 chars and may contain a digit ("B6", "9E"),
    /// so split after the designator rather than at the first digit.
    private static func splitIndex(_ s: String) -> String.Index? {
        let chars = Array(s)
        guard chars.count >= 3 else { return nil }
        for designatorLength in [2, 3] where designatorLength < chars.count {
            let designator = chars[0..<designatorLength]
            let rest = chars[designatorLength...]
            let designatorOK = designator.allSatisfy { $0.isLetter || $0.isNumber } && designator.contains { $0.isLetter }
            let restOK = rest.allSatisfy(\.isNumber) && rest.count <= 5
            if designatorOK && restOK {
                // Prefer 2-char IATA unless the third char is a letter (3-char ICAO like "UAL").
                if designatorLength == 2 && chars[2].isLetter { continue }
                return s.index(s.startIndex, offsetBy: designatorLength)
            }
        }
        return nil
    }
}

public enum FlightDate {
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func utcDayString(_ date: Date) -> String {
        dayString(date, in: TimeZone(identifier: "UTC")!)
    }

    /// "yyyy-MM-dd" for `date` as seen in `timeZone`.
    public static func dayString(_ date: Date, in timeZone: TimeZone) -> String {
        var cal = utcCalendar
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
