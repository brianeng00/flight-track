import Foundation

/// Our own view of where a flight is, derived from provider status + times + position.
/// Ordered: a tracked flight never moves backwards except into `canceled`/`diverted`.
public enum FlightPhase: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case scheduled
    case boarding
    /// Pushed back / taxiing out.
    case departed
    case airborne
    /// On the runway at the destination, taxiing in.
    case landed
    /// At the arrival gate.
    case arrived
    case diverted
    case canceled

    var rank: Int {
        switch self {
        case .scheduled: return 0
        case .boarding: return 1
        case .departed: return 2
        case .airborne: return 3
        case .landed: return 4
        case .arrived: return 5
        case .diverted: return 6
        case .canceled: return 7
        }
    }

    public static func < (lhs: FlightPhase, rhs: FlightPhase) -> Bool { lhs.rank < rhs.rank }

    public var isTerminal: Bool { self == .arrived || self == .canceled }
    public var isInAir: Bool { self == .airborne || self == .diverted }
}

public enum PhaseResolver {
    /// Best phase for `snapshot` at `now`. `position` may come from OpenSky rather than the snapshot.
    public static func resolve(_ snapshot: FlightSnapshot, position: LivePosition?, now: Date) -> FlightPhase {
        let dep = snapshot.departure.times
        let arr = snapshot.arrival.times
        let pos = position ?? snapshot.position

        switch snapshot.status {
        case .canceled, .canceledUncertain:
            return .canceled
        case .diverted:
            return .diverted
        case .arrived:
            // AeroDataBox may flip to Arrived at touchdown. If gate-in is still ahead of runway time
            // and in the future, we're taxiing in.
            if let landed = arr.runway, let gateIn = arr.revised, gateIn > landed, gateIn > now {
                return .landed
            }
            return .arrived
        default:
            break
        }

        // Landed per runway time (in the past) but no Arrived status yet.
        if let landed = arr.runway, landed <= now {
            if let gateIn = arr.revised, gateIn <= now, gateIn > landed { return .arrived }
            return .landed
        }
        if snapshot.status == .enRoute || snapshot.status == .approaching { return .airborne }
        if let pos, pos.isAirborne, isFresh(pos, now: now) { return .airborne }
        if let takeoff = dep.runway, takeoff <= now { return .airborne }

        switch snapshot.status {
        case .departed:
            return .departed
        case .boarding, .gateClosed:
            return .boarding
        default:
            // Deliberately no "estimated gate-out has passed, so it left" guess: a stale estimate
            // would claim a pushback that never happened. Wait for status, runway time or position.
            return .scheduled
        }
    }

    /// Keeps the phase monotonic: providers occasionally flap (Departed -> Delayed) between polls.
    public static func advance(from old: FlightPhase?, to new: FlightPhase) -> FlightPhase {
        guard let old else { return new }
        if new == .canceled || new == .diverted { return new }
        // A cancellation or diversion can be walked back by the airline (reinstated flight).
        if old == .canceled || old == .diverted { return new }
        return max(old, new)
    }

    static func isFresh(_ p: LivePosition, now: Date) -> Bool {
        now.timeIntervalSince(p.reportedAt) < 20 * 60
    }
}
