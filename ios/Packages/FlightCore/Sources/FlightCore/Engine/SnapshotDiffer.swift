import Foundation

/// Tunable alert thresholds. Defaults follow the plan; tests pin them.
public struct AlertRules: Codable, Hashable, Sendable {
    /// Departure delay at or above this is worth a banner.
    public var delayAlertMinutes = 15
    /// Once delayed, notify again when the time moves by at least this much.
    public var timeChangeStepMinutes = 10
    /// Arrival ETA moves are noisier in flight; use a wider step.
    public var arrivalStepMinutes = 15
    /// "Boarding soon (est.)" fires this long before best departure.
    public var boardingLeadMinutes = 35
    /// Minimum turnaround between the inbound leg's gate arrival and our departure.
    public var minTurnaroundMinutes = 35
    /// Inbound lateness at or above this is worth a banner.
    public var inboundLateAlertMinutes = 10

    public init() {}
}

public enum SnapshotDiffer {
    /// Compares `old` and `new` for the same leg and returns what changed, in the order a person
    /// would want to hear it. Pure: no clocks, no I/O.
    public static func diff(
        old: FlightSnapshot?, new: FlightSnapshot, oldPhase: FlightPhase?, newPhase: FlightPhase,
        now: Date, rules: AlertRules = AlertRules()
    ) -> [FlightEvent] {
        var events: [FlightEvent] = []

        // Cancel / divert / reinstate first: they trump everything else.
        if newPhase == .canceled, oldPhase != .canceled { return [.canceled] }
        if oldPhase == .canceled, newPhase != .canceled { events.append(.reinstated) }
        if newPhase == .diverted, oldPhase != .diverted {
            let newArrival = new.arrival.airport
            let changed = old.map { !$0.arrival.airport.isSameAirport(as: newArrival) } ?? false
            events.append(.diverted(to: changed ? newArrival : nil))
        }

        events += phaseEvents(from: oldPhase, to: newPhase)

        if let old {
            events += gateEvents(side: .departure, old: old.departure, new: new.departure)
            events += gateEvents(side: .arrival, old: old.arrival, new: new.arrival)
            // Stop departure-time alerts at pushback: from then on "departed" says it all.
            if newPhase < .departed {
                events += timeEvents(side: .departure, old: old.departure, new: new.departure,
                                     step: rules.timeChangeStepMinutes, rules: rules)
            }
            if newPhase >= .departed && newPhase < .landed {
                events += timeEvents(side: .arrival, old: old.arrival, new: new.arrival,
                                     step: rules.arrivalStepMinutes, rules: rules)
            }
            if let belt = new.arrival.baggageBelt, belt != old.arrival.baggageBelt {
                events.append(.baggageBelt(belt: belt, previous: old.arrival.baggageBelt))
            }
            if let newReg = new.aircraft?.registration, let oldReg = old.aircraft?.registration, newReg != oldReg {
                events.append(.aircraftChanged(from: oldReg, to: newReg))
            }
        }
        // No `old` = first sighting (flight just added). Nothing has *changed* yet, so no
        // alerts; the screen and Live Activity already show the current gate and times.

        if newPhase == .scheduled, let best = new.departure.times.bestGate,
           now >= best.addingTimeInterval(TimeInterval(-rules.boardingLeadMinutes * 60)), now < best {
            events.append(.boardingSoonEstimated(departure: best))
        }
        return events
    }

    static func phaseEvents(from old: FlightPhase?, to new: FlightPhase) -> [FlightEvent] {
        // `diverted` ranks above landed/arrived, so allow forward milestones out of it explicitly.
        guard let old, new != old, new != .canceled, new != .diverted, new > old || old == .diverted else { return [] }
        // Emit only the newest milestone crossed. A poll gap from boarding straight to
        // airborne should say "took off", not also "departed gate" a moment later.
        switch new {
        case .boarding: return [.boardingStarted]
        case .departed: return [.departedGate]
        case .airborne: return old == .diverted ? [] : [.tookOff]
        case .landed: return [.landed]
        case .arrived: return [.arrivedAtGate]
        case .scheduled, .canceled, .diverted: return []
        }
    }

    static func gateEvents(side: FlightSide, old: Movement, new: Movement) -> [FlightEvent] {
        var events: [FlightEvent] = []
        if let newTerminal = new.terminal, newTerminal != old.terminal, old.terminal != nil {
            events.append(.terminalChanged(side: side, from: old.terminal, to: newTerminal))
        }
        switch (old.gate, new.gate) {
        case (nil, let g?): events.append(.gateAssigned(side: side, gate: g))
        case (let a?, let b?) where a != b: events.append(.gateChanged(side: side, from: a, to: b))
        default: break
        }
        return events
    }

    static func timeEvents(side: FlightSide, old: Movement, new: Movement, step: Int, rules: AlertRules) -> [FlightEvent] {
        guard let newBest = new.times.bestGate else { return [] }
        let oldBest = old.times.bestGate
        let newDelay = new.delayMinutes ?? 0
        let oldDelay = old.delayMinutes ?? 0
        let movedMinutes = oldBest.map { Int((newBest.timeIntervalSince($0) / 60).rounded()) } ?? 0

        let crossedIntoDelay = newDelay >= rules.delayAlertMinutes && oldDelay < rules.delayAlertMinutes
        let recovered = oldDelay >= rules.delayAlertMinutes && newDelay < rules.delayAlertMinutes
        let bigMove = abs(movedMinutes) >= step && (newDelay >= rules.delayAlertMinutes || movedMinutes < 0 || recovered)
        guard crossedIntoDelay || recovered || bigMove else { return [] }
        return [.timeChanged(side: side, from: oldBest, to: newBest, delayMinutes: newDelay)]
    }
}

public enum InboundAircraftCheck {
    /// From all legs this tail flies today, pick the one that brings it to our departure airport.
    public static func findInbound(legs: [FlightSnapshot], for flight: FlightSnapshot) -> FlightSnapshot? {
        guard let ourDeparture = flight.departure.times.scheduled else { return nil }
        return legs
            .filter { $0.legKey != flight.legKey }
            .filter { $0.arrival.airport.isSameAirport(as: flight.departure.airport) }
            .filter { ($0.arrival.times.scheduled ?? .distantFuture) < ourDeparture }
            .max { ($0.arrival.times.scheduled ?? .distantPast) < ($1.arrival.times.scheduled ?? .distantPast) }
    }

    /// Minutes our departure would slip because of the inbound leg (0 when it's fine).
    public static func minutesLate(inbound: FlightSnapshot, ours: FlightSnapshot, rules: AlertRules = AlertRules()) -> Int {
        guard inbound.status != .arrived,
              let inboundETA = inbound.arrival.times.bestGate,
              let ourDeparture = ours.departure.times.bestGate else { return 0 }
        let readyAt = inboundETA.addingTimeInterval(TimeInterval(rules.minTurnaroundMinutes * 60))
        return max(0, Int((readyAt.timeIntervalSince(ourDeparture) / 60).rounded()))
    }

    /// Event when lateness crosses the alert line or recovers.
    public static func event(previousMinutesLate: Int, inbound: FlightSnapshot, ours: FlightSnapshot,
                             rules: AlertRules = AlertRules()) -> FlightEvent? {
        let now = minutesLate(inbound: inbound, ours: ours, rules: rules)
        if now >= rules.inboundLateAlertMinutes,
           previousMinutesLate < rules.inboundLateAlertMinutes || now - previousMinutesLate >= 15,
           let eta = inbound.arrival.times.bestGate {
            return .inboundLate(inboundNumber: inbound.number, inboundETA: eta, minutesLate: now)
        }
        if previousMinutesLate >= rules.inboundLateAlertMinutes, now < rules.inboundLateAlertMinutes {
            return .inboundRecovered(inboundNumber: inbound.number)
        }
        return nil
    }
}
