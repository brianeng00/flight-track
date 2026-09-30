import Foundation

/// Tracks AeroDataBox unit spend against the monthly plan (free Basic = 600 units).
public struct UnitBudget: Codable, Hashable, Sendable {
    public var monthlyUnits: Int
    /// Units held back so an in-progress trip can always finish.
    public var reserveUnits: Int
    public var usedUnits: Int
    /// Day of month the marketplace resets your quota (check your plan page; default the 1st).
    public var resetDay: Int
    public var periodStart: Date

    public init(monthlyUnits: Int = 600, reserveUnits: Int = 40, usedUnits: Int = 0, resetDay: Int = 1, periodStart: Date) {
        self.monthlyUnits = monthlyUnits
        self.reserveUnits = reserveUnits
        self.usedUnits = usedUnits
        self.resetDay = resetDay
        self.periodStart = periodStart
    }

    public var remaining: Int { max(0, monthlyUnits - usedUnits) }
    public var fractionRemaining: Double { monthlyUnits > 0 ? Double(remaining) / Double(monthlyUnits) : 0 }

    /// Rolls over to a fresh period when `now` has passed the next reset date.
    public mutating func rollIfNeeded(now: Date, calendar: Calendar = .current) {
        guard let next = Self.nextReset(after: periodStart, resetDay: resetDay, calendar: calendar), now >= next else { return }
        var start = next
        while let following = Self.nextReset(after: start, resetDay: resetDay, calendar: calendar), following <= now {
            start = following
        }
        periodStart = start
        usedUnits = 0
    }

    static func nextReset(after date: Date, resetDay: Int, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = min(max(resetDay, 1), 28)
        guard let thisMonth = calendar.date(from: comps) else { return nil }
        if thisMonth > date { return thisMonth }
        return calendar.date(byAdding: .month, value: 1, to: thisMonth)
    }

    /// `critical` polls (flight is in its active window) may dip into the reserve; others may not.
    public func canSpend(_ units: Int, critical: Bool) -> Bool {
        critical ? remaining >= units : remaining - units >= reserveUnits
    }

    public mutating func spend(_ units: Int) { usedUnits += units }
}

/// Which request kinds are due, and how often each should run in the current phase.
public struct PollPlan: Hashable, Sendable {
    /// AeroDataBox status poll interval, nil = don't poll.
    public var status: TimeInterval?
    /// OpenSky position poll interval, nil = don't poll.
    public var position: TimeInterval?
    /// AeroDataBox by-registration poll for the inbound leg, nil = don't poll.
    public var inbound: TimeInterval?
    /// True inside the active trip window: may use the reserve, and wants the keep-alive running.
    public var isActiveWindow: Bool

    public static let idle = PollPlan(status: nil, position: nil, inbound: nil, isActiveWindow: false)
}

public enum PollScheduler {
    /// How long before departure live tracking (Live Activity + keep-alive) begins.
    public static let activeWindowLead: TimeInterval = 3 * 3600
    /// How long after landing we keep going for gate + baggage belt.
    public static let postArrivalTail: TimeInterval = 45 * 60

    /// Cadence for `flight` at `now`. Numbers follow the plan's table (about 25 status calls per flight).
    public static func plan(for flight: TrackedFlight, now: Date, budget: UnitBudget) -> PollPlan {
        let snap = flight.snapshot
        let departure = snap.departure.times.bestGate ?? snap.departure.times.scheduled
        let arrival = snap.arrival.times.bestGate ?? snap.arrival.times.scheduled
        let hasTail = snap.aircraft?.registration != nil
        let stretch = budget.fractionRemaining < 0.3 ? 2.0 : 1.0

        var plan: PollPlan
        switch flight.phase {
        case .canceled:
            return .idle
        case .scheduled, .boarding:
            guard let departure else { return PollPlan(status: 6 * 3600, position: nil, inbound: nil, isActiveWindow: false) }
            let untilDeparture = departure.timeIntervalSince(now)
            if untilDeparture > activeWindowLead {
                // Outside the window: slow background refresh only (iOS decides when it actually runs).
                plan = PollPlan(status: untilDeparture > 24 * 3600 ? 12 * 3600 : 3 * 3600,
                                position: nil, inbound: nil, isActiveWindow: false)
            } else {
                let status: TimeInterval = untilDeparture > 45 * 60 ? 20 * 60 : 10 * 60
                let inboundDone = flight.inbound?.status == .arrived
                plan = PollPlan(status: status, position: nil,
                                inbound: hasTail && !inboundDone ? 40 * 60 : nil, isActiveWindow: true)
            }
        case .departed:
            plan = PollPlan(status: 15 * 60, position: 60, inbound: nil, isActiveWindow: true)
        case .airborne, .diverted:
            let nearArrival = arrival.map { $0.timeIntervalSince(now) < 30 * 60 } ?? false
            plan = PollPlan(status: nearArrival ? 15 * 60 : 45 * 60, position: 60, inbound: nil, isActiveWindow: true)
        case .landed:
            plan = PollPlan(status: 10 * 60, position: nil, inbound: nil, isActiveWindow: true)
        case .arrived:
            let landedAt = snap.arrival.times.runway ?? snap.arrival.times.bestGate ?? now
            let done = snap.arrival.baggageBelt != nil || now.timeIntervalSince(landedAt) > postArrivalTail
            plan = done ? .idle : PollPlan(status: 10 * 60, position: nil, inbound: nil, isActiveWindow: true)
        }

        plan.status = plan.status.map { $0 * stretch }
        plan.inbound = plan.inbound.map { $0 * stretch }
        return plan
    }

    /// True when a request with `interval` last made at `last` should run now.
    public static func isDue(last: Date?, interval: TimeInterval?, now: Date) -> Bool {
        guard let interval else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval - 5 // small slack for timer jitter
    }

    /// When live tracking should end (Live Activity dismissed, keep-alive off).
    public static func trackingEnds(for flight: TrackedFlight, now: Date) -> Bool {
        switch flight.phase {
        case .canceled:
            return true
        case .arrived:
            let arrivedAt = flight.snapshot.arrival.times.revised ?? flight.snapshot.arrival.times.runway ?? now
            let belt = flight.snapshot.arrival.baggageBelt != nil
            return now.timeIntervalSince(arrivedAt) > (belt ? 30 * 60 : 60 * 60)
        default:
            return false
        }
    }

    /// Rough units a flight costs end to end, for the "flights left this month" readout.
    public static let estimatedUnitsPerFlight = 50
}
