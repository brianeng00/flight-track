import Foundation

/// Status color bucket. Flighty-style: green on time, amber moderate delay, red big delay or canceled.
public enum StatusTone: String, Codable, Hashable, Sendable {
    case onTime
    case minorDelay
    case majorDelay
    case canceled
    case diverted
    case unknown
}

public enum FlightFormat {
    /// "4:05 PM" in the airport's own time zone.
    public static func localTime(_ date: Date?, timeZone: TimeZone, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        guard let date else { return "--:--" }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// "1h 12m", "45m", "0m". Negative spans clamp to 0.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// "On time", "Delayed 25m", "12m early", "Canceled".
    public static func statusText(delayMinutes: Int?, phase: FlightPhase) -> String {
        switch phase {
        case .canceled: return "Canceled"
        case .diverted: return "Diverted"
        default: break
        }
        guard let d = delayMinutes else { return phase == .scheduled ? "Scheduled" : "On time" }
        if d >= 5 { return "Delayed \(duration(TimeInterval(d * 60)))" }
        if d <= -5 { return "\(duration(TimeInterval(-d * 60))) early" }
        return "On time"
    }

    public static func tone(delayMinutes: Int?, phase: FlightPhase) -> StatusTone {
        switch phase {
        case .canceled: return .canceled
        case .diverted: return .diverted
        default: break
        }
        guard let d = delayMinutes else { return .unknown }
        if d >= 45 { return .majorDelay }
        if d >= 15 { return .minorDelay }
        return .onTime
    }

    /// The delay that matters right now: departure until we leave, arrival after.
    public static func relevantDelay(_ flight: TrackedFlight) -> Int? {
        flight.phase >= .departed && flight.phase != .canceled
            ? flight.snapshot.arrival.delayMinutes
            : flight.snapshot.departure.delayMinutes
    }

    /// "Gate C14" / "T2 · Gate C14" / "Gate TBD".
    public static func gateLine(_ m: Movement) -> String {
        let gate = "Gate \(m.gate ?? "TBD")"
        guard let terminal = m.terminal else { return gate }
        return "T\(terminal) · \(gate)"
    }
}

/// Banner text for an event. Short, Flighty-style: what changed, then what it means.
public struct AlertContent: Hashable, Sendable {
    public var title: String
    public var body: String
    /// Groups a flight's notifications together in Notification Center.
    public var threadID: String
}

public enum AlertFormatter {
    public static func content(for event: FlightEvent, flight: TrackedFlight) -> AlertContent {
        let snap = flight.snapshot
        let n = snap.number
        let route = "\(snap.departure.airport.code) → \(snap.arrival.airport.code)"
        let depTZ = snap.departure.airport.timeZone
        let arrTZ = snap.arrival.airport.timeZone
        let thread = "flight-\(flight.id.uuidString)"
        func make(_ title: String, _ body: String) -> AlertContent { AlertContent(title: title, body: body, threadID: thread) }

        switch event {
        case .gateAssigned(let side, let gate):
            return side == .departure
                ? make("\(n) departs from Gate \(gate)", "\(route) · Departs \(FlightFormat.localTime(snap.departure.times.bestGate, timeZone: depTZ))")
                : make("\(n) arrives at Gate \(gate)", "\(snap.arrival.airport.code) · Arrives \(FlightFormat.localTime(snap.arrival.times.bestGate, timeZone: arrTZ))")
        case .gateChanged(let side, let from, let to):
            return make("Gate change: \(from) → \(to)",
                        "\(n) \(side == .departure ? "now departs from" : "now arrives at") Gate \(to)")
        case .terminalChanged(let side, _, let to):
            return make("Terminal change", "\(n) \(side == .departure ? "departs from" : "arrives at") Terminal \(to)")
        case .timeChanged(let side, _, let to, let delay):
            let tz = side == .departure ? depTZ : arrTZ
            let verb = side == .departure ? "departs" : "arrives"
            let when = FlightFormat.localTime(to, timeZone: tz)
            if delay >= 5 {
                return make("\(n) delayed \(FlightFormat.duration(TimeInterval(delay * 60)))", "Now \(verb) \(when) · \(route)")
            } else if delay <= -5 {
                return make("\(n) \(side == .departure ? "leaving" : "arriving") early", "Now \(verb) \(when), \(FlightFormat.duration(TimeInterval(-delay * 60))) early")
            }
            return make("\(n) back on time", "Now \(verb) \(when) · \(route)")
        case .boardingStarted:
            return make("\(n) is boarding", FlightFormat.gateLine(snap.departure))
        case .boardingSoonEstimated(let dep):
            return make("\(n) boarding soon", "Estimated, based on \(FlightFormat.localTime(dep, timeZone: depTZ)) departure · \(FlightFormat.gateLine(snap.departure))")
        case .departedGate:
            return make("\(n) pushed back", "Taxiing at \(snap.departure.airport.code)")
        case .tookOff:
            let eta = snap.arrival.times.bestGate
            return make("\(n) took off", "Arrives \(FlightFormat.localTime(eta, timeZone: arrTZ)) at \(snap.arrival.airport.code)")
        case .landed:
            let gate = snap.arrival.gate.map { " · Gate \($0)" } ?? ""
            return make("\(n) landed", "\(snap.arrival.airport.code)\(gate)")
        case .arrivedAtGate:
            let belt = snap.arrival.baggageBelt.map { " · Bags on belt \($0)" } ?? ""
            return make("\(n) arrived", "At \(FlightFormat.gateLine(snap.arrival))\(belt)")
        case .canceled:
            return make("\(n) canceled", "\(route). Check the airline app to rebook.")
        case .reinstated:
            return make("\(n) is back on", "Airline reinstated the flight · \(route)")
        case .diverted(let to):
            return make("\(n) diverted", to.map { "Now heading to \($0.code) (\($0.name))" } ?? "Check the airline for the new destination")
        case .baggageBelt(let belt, let previous):
            return previous == nil
                ? make("Bags for \(n): belt \(belt)", snap.arrival.airport.code)
                : make("Baggage belt changed to \(belt)", "\(n) · was \(previous ?? "")")
        case .aircraftChanged(_, let to):
            return make("Aircraft swap", "\(n) now operated by \(to)")
        case .inboundLate(let inbound, let eta, let late):
            return make("Your plane is running late",
                        "Inbound \(inbound) lands \(FlightFormat.localTime(eta, timeZone: depTZ)). \(n) could leave about \(FlightFormat.duration(TimeInterval(late * 60))) late.")
        case .inboundRecovered(let inbound):
            return make("Your plane caught up", "Inbound \(inbound) is back on schedule for \(n)")
        }
    }
}
