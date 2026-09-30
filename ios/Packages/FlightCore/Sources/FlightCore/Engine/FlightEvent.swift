import Foundation

public enum FlightSide: String, Codable, Hashable, Sendable {
    case departure
    case arrival
}

/// Something that changed between two polls and may deserve an alert.
public enum FlightEvent: Codable, Hashable, Sendable {
    case gateAssigned(side: FlightSide, gate: String)
    case gateChanged(side: FlightSide, from: String, to: String)
    case terminalChanged(side: FlightSide, from: String?, to: String)
    /// Best gate time moved. `delayMinutes` is relative to schedule (negative = early).
    case timeChanged(side: FlightSide, from: Date?, to: Date, delayMinutes: Int)
    case boardingStarted
    /// Our estimate (no provider boarding status yet): best departure minus the boarding lead.
    case boardingSoonEstimated(departure: Date)
    case departedGate
    case tookOff
    case landed
    case arrivedAtGate
    case canceled
    case reinstated
    case diverted(to: AirportRef?)
    case baggageBelt(belt: String, previous: String?)
    case aircraftChanged(from: String?, to: String)
    /// The aircraft's previous leg is running late enough to delay us.
    case inboundLate(inboundNumber: String, inboundETA: Date, minutesLate: Int)
    case inboundRecovered(inboundNumber: String)

    /// Stable key for "already notified" bookkeeping and notification identifiers.
    public var dedupeKey: String {
        switch self {
        case .gateAssigned(let side, let gate): return "gate.\(side.rawValue).\(gate)"
        case .gateChanged(let side, _, let to): return "gate.\(side.rawValue).\(to)"
        case .terminalChanged(let side, _, let to): return "terminal.\(side.rawValue).\(to)"
        case .timeChanged(let side, _, let to, _): return "time.\(side.rawValue).\(Int(to.timeIntervalSince1970 / 60))"
        case .boardingStarted: return "boarding"
        case .boardingSoonEstimated: return "boardingSoon"
        case .departedGate: return "departedGate"
        case .tookOff: return "tookOff"
        case .landed: return "landed"
        case .arrivedAtGate: return "arrivedAtGate"
        case .canceled: return "canceled"
        case .reinstated: return "reinstated"
        case .diverted(let to): return "diverted.\(to?.code ?? "?")"
        case .baggageBelt(let belt, _): return "belt.\(belt)"
        case .aircraftChanged(_, let to): return "aircraft.\(to)"
        case .inboundLate(_, _, let m): return "inboundLate.\(m / 5 * 5)"
        case .inboundRecovered: return "inboundRecovered"
        }
    }

    /// Whether this deserves a banner. Some events only refresh the Live Activity.
    public var notifies: Bool {
        switch self {
        case .aircraftChanged, .terminalChanged: return false
        default: return true
        }
    }
}
