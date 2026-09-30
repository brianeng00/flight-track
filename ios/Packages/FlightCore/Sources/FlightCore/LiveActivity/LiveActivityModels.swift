import Foundation

/// A point on the Live Activity route drawing, normalized to 0...1 in both axes (y down).
public struct RoutePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        // Three decimals is sub-pixel on any Live Activity and keeps the payload small.
        self.x = (x * 1000).rounded() / 1000
        self.y = (y * 1000).rounded() / 1000
    }
}

/// Values fixed for the life of a Live Activity (ActivityKit "attributes").
public struct LiveActivityStatic: Codable, Hashable, Sendable {
    public var flightID: UUID
    public var number: String
    public var airlineIATA: String?
    public var departureCode: String
    public var arrivalCode: String
    public var departureCity: String?
    public var arrivalCity: String?
    public var departureTimeZoneID: String?
    public var arrivalTimeZoneID: String?
    /// Great-circle route, already projected to match `mapImageFile` when there is one.
    public var route: [RoutePoint]
    /// File name of the pre-rendered route map in the App Group container, if rendered.
    public var mapImageFile: String?

    public init(flightID: UUID, number: String, airlineIATA: String?, departureCode: String, arrivalCode: String,
                departureCity: String?, arrivalCity: String?, departureTimeZoneID: String?, arrivalTimeZoneID: String?,
                route: [RoutePoint], mapImageFile: String?) {
        self.flightID = flightID
        self.number = number
        self.airlineIATA = airlineIATA
        self.departureCode = departureCode
        self.arrivalCode = arrivalCode
        self.departureCity = departureCity
        self.arrivalCity = arrivalCity
        self.departureTimeZoneID = departureTimeZoneID
        self.arrivalTimeZoneID = arrivalTimeZoneID
        self.route = route
        self.mapImageFile = mapImageFile
    }
}

/// The phase-specific bottom line of the Live Activity. Dates stay dates so the widget can use
/// `Text(timerInterval:)` and keep counting with no updates (e.g. in the air, no Wi-Fi).
public enum LiveHeadline: Codable, Hashable, Sendable {
    case departsIn(Date)
    case boardingSoon(Date)
    case boarding(gate: String?)
    case taxiingOut
    case landsIn(Date)
    case landedTaxiing(gate: String?)
    case baggage(belt: String)
    case arrived(gate: String?)
    case canceled
    case diverted(code: String?)
    /// No usable times yet.
    case scheduled
}

/// Values that change over the life of a Live Activity (ActivityKit "content state").
public struct LiveActivityState: Codable, Hashable, Sendable {
    public var phase: FlightPhase
    public var statusText: String
    public var tone: StatusTone
    public var departureGate: String?
    public var departureTerminal: String?
    public var arrivalGate: String?
    public var arrivalTerminal: String?
    public var baggageBelt: String?
    public var departureScheduled: Date?
    public var departureBest: Date?
    public var arrivalScheduled: Date?
    public var arrivalBest: Date?
    /// Takeoff and landing estimate: the widget animates progress between them on its own.
    public var takeoffAt: Date?
    public var landingAt: Date?
    /// Progress as of `updatedAt` (position-based when we had a fix).
    public var progress: Double
    public var altitudeFt: Int?
    public var groundSpeedKt: Int?
    /// Set when diverted to somewhere other than `LiveActivityStatic.arrivalCode`.
    public var arrivalCodeOverride: String?
    public var headline: LiveHeadline
    public var updatedAt: Date

    public init(phase: FlightPhase, statusText: String, tone: StatusTone, departureGate: String?, departureTerminal: String?,
                arrivalGate: String?, arrivalTerminal: String?, baggageBelt: String?, departureScheduled: Date?,
                departureBest: Date?, arrivalScheduled: Date?, arrivalBest: Date?, takeoffAt: Date?, landingAt: Date?,
                progress: Double, altitudeFt: Int?, groundSpeedKt: Int?, arrivalCodeOverride: String?,
                headline: LiveHeadline, updatedAt: Date) {
        self.phase = phase
        self.statusText = statusText
        self.tone = tone
        self.departureGate = departureGate
        self.departureTerminal = departureTerminal
        self.arrivalGate = arrivalGate
        self.arrivalTerminal = arrivalTerminal
        self.baggageBelt = baggageBelt
        self.departureScheduled = departureScheduled
        self.departureBest = departureBest
        self.arrivalScheduled = arrivalScheduled
        self.arrivalBest = arrivalBest
        self.takeoffAt = takeoffAt
        self.landingAt = landingAt
        self.progress = progress
        self.altitudeFt = altitudeFt
        self.groundSpeedKt = groundSpeedKt
        self.arrivalCodeOverride = arrivalCodeOverride
        self.headline = headline
        self.updatedAt = updatedAt
    }

    /// True when the scheduled time moved enough to show it struck through.
    public var departureTimeChanged: Bool { Self.moved(departureScheduled, departureBest) }
    public var arrivalTimeChanged: Bool { Self.moved(arrivalScheduled, arrivalBest) }

    static func moved(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(b.timeIntervalSince(a)) >= 5 * 60
    }
}

public enum LiveActivityBuilder {
    /// Apple caps attributes + state at 4 KB combined; we check against this in tests and at runtime.
    public static let payloadLimitBytes = 4096
    /// A Live Activity with no update for this long shows as stale instead of silently wrong.
    public static let staleAfter: TimeInterval = 30 * 60

    public static func attributes(for flight: TrackedFlight, route: [RoutePoint]? = nil, mapImageFile: String? = nil) -> LiveActivityStatic {
        let s = flight.snapshot
        let points = route ?? defaultRoute(for: flight)
        return LiveActivityStatic(
            flightID: flight.id, number: s.number, airlineIATA: s.airlineIATA,
            departureCode: s.departure.airport.code, arrivalCode: s.arrival.airport.code,
            departureCity: s.departure.airport.city, arrivalCity: s.arrival.airport.city,
            departureTimeZoneID: s.departure.airport.timeZoneID, arrivalTimeZoneID: s.arrival.airport.timeZoneID,
            route: points, mapImageFile: mapImageFile)
    }

    public static func state(for flight: TrackedFlight, now: Date, rules: AlertRules = AlertRules()) -> LiveActivityState {
        let s = flight.snapshot
        let dep = s.departure, arr = s.arrival
        let delay = FlightFormat.relevantDelay(flight)
        let pos = flight.position.flatMap { now.timeIntervalSince($0.reportedAt) < 15 * 60 ? $0 : nil }
        let landingAt = arr.times.runway ?? arr.times.bestGate
        return LiveActivityState(
            phase: flight.phase,
            statusText: FlightFormat.statusText(delayMinutes: delay, phase: flight.phase),
            tone: FlightFormat.tone(delayMinutes: delay, phase: flight.phase),
            departureGate: dep.gate, departureTerminal: dep.terminal,
            arrivalGate: arr.gate, arrivalTerminal: arr.terminal, baggageBelt: arr.baggageBelt,
            departureScheduled: dep.times.scheduled, departureBest: dep.times.bestGate,
            arrivalScheduled: arr.times.scheduled, arrivalBest: arr.times.bestGate,
            takeoffAt: dep.times.runway ?? (flight.phase >= .airborne ? dep.times.bestGate : nil),
            landingAt: landingAt,
            progress: flight.progress(now: now),
            altitudeFt: flight.phase.isInAir ? pos?.altitudeFt : nil,
            groundSpeedKt: flight.phase.isInAir ? pos?.groundSpeedKt : nil,
            arrivalCodeOverride: flight.phase == .diverted ? arr.airport.code : nil,
            headline: headline(for: flight, landingAt: landingAt, now: now, rules: rules),
            updatedAt: now)
    }

    static func headline(for flight: TrackedFlight, landingAt: Date?, now: Date, rules: AlertRules) -> LiveHeadline {
        let s = flight.snapshot
        switch flight.phase {
        case .canceled: return .canceled
        case .diverted: return .diverted(code: s.arrival.airport.code)
        case .scheduled:
            guard let best = s.departure.times.bestGate else { return .scheduled }
            if now >= best.addingTimeInterval(TimeInterval(-rules.boardingLeadMinutes * 60)) { return .boardingSoon(best) }
            return .departsIn(best)
        case .boarding: return .boarding(gate: s.departure.gate)
        case .departed: return .taxiingOut
        case .airborne:
            guard let landingAt else { return .scheduled }
            return .landsIn(landingAt)
        case .landed: return .landedTaxiing(gate: s.arrival.gate)
        case .arrived:
            if let belt = s.arrival.baggageBelt { return .baggage(belt: belt) }
            return .arrived(gate: s.arrival.gate)
        }
    }

    /// Encoded size of what ActivityKit will store. Must stay under `payloadLimitBytes`.
    public static func payloadSize(_ attributes: LiveActivityStatic, _ state: LiveActivityState) -> Int {
        let encoder = JSONEncoder()
        let a = (try? encoder.encode(attributes).count) ?? 0
        let s = (try? encoder.encode(state).count) ?? 0
        return a + s
    }

    /// Route drawing when no map snapshot exists: great circle, equirectangular with cos(lat)
    /// correction, fitted into the unit square with padding and preserved aspect ratio.
    public static func defaultRoute(for flight: TrackedFlight, count: Int = 16) -> [RoutePoint] {
        guard let a = flight.departureCoordinate, let b = flight.arrivalCoordinate else {
            return [RoutePoint(x: 0.1, y: 0.5), RoutePoint(x: 0.9, y: 0.5)]
        }
        return RouteProjection.fit(Geo.greatCircle(a, b, count: count))
    }
}

public enum RouteProjection {
    /// Projects coordinates into 0...1 (y down), centered, `padding` on every side.
    public static func fit(_ coords: [Coordinate], padding: Double = 0.1) -> [RoutePoint] {
        guard !coords.isEmpty else { return [] }
        let midLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let k = cos(midLat * Double.pi / 180)
        // Unwrap longitudes so a route over the antimeridian stays continuous.
        var lons: [Double] = []
        for c in coords {
            var lon = c.longitude
            if let prev = lons.last {
                while lon - prev > 180 { lon -= 360 }
                while prev - lon > 180 { lon += 360 }
            }
            lons.append(lon)
        }
        let xs = lons.map { $0 * k }
        let ys = coords.map { -$0.latitude }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let span = max(maxX - minX, maxY - minY, 1e-9)
        let usable = 1 - 2 * padding
        let offX = (1 - (maxX - minX) / span * usable) / 2
        let offY = (1 - (maxY - minY) / span * usable) / 2
        return zip(xs, ys).map { x, y in
            RoutePoint(x: offX + (x - minX) / span * usable, y: offY + (y - minY) / span * usable)
        }
    }

    /// Position `fraction` (0...1) along a polyline, by segment length.
    public static func point(along route: [RoutePoint], fraction: Double) -> (point: RoutePoint, angleRadians: Double) {
        guard route.count >= 2 else { return (route.first ?? RoutePoint(x: 0.5, y: 0.5), 0) }
        let lengths = zip(route, route.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var remaining = min(max(fraction, 0), 1) * total
        for (i, len) in lengths.enumerated() {
            let a = route[i], b = route[i + 1]
            if remaining <= len || i == lengths.count - 1 {
                let t = len > 0 ? min(remaining / len, 1) : 0
                return (RoutePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), atan2(b.y - a.y, b.x - a.x))
            }
            remaining -= len
        }
        return (route.last!, 0)
    }
}
