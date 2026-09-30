import Foundation

/// Outcome of one refresh pass over a tracked flight.
public struct RefreshResult: Sendable {
    public var flight: TrackedFlight
    /// Events not delivered before. Their keys are already recorded on `flight`.
    public var newEvents: [FlightEvent]
    public var unitsSpent: Int
    public var didPollStatus: Bool
    public var didPollPosition: Bool
}

/// Runs whichever polls are due for a flight, then turns the answers into phase + events.
/// Same logic on the phone (free mode) and, later, ported to the server (push mode).
public struct FlightEngine: Sendable {
    public let status: FlightStatusProvider
    public let position: PositionProvider?
    public var rules: AlertRules
    /// Cap on stored track points (about 33 hours at one per minute).
    public var maxTrackPoints = 2000

    public init(status: FlightStatusProvider, position: PositionProvider?, rules: AlertRules = AlertRules()) {
        self.status = status
        self.position = position
        self.rules = rules
    }

    /// Looks up legs for the Add Flight screen. Costs one status call.
    public func search(number: String, date: String, budget: inout UnitBudget, now: Date = Date()) async throws -> [FlightSnapshot] {
        budget.rollIfNeeded(now: now)
        guard budget.canSpend(status.unitsPerCall, critical: true) else { throw ProviderError.budgetExhausted }
        budget.spend(status.unitsPerCall)
        return try await status.flights(number: number, date: date)
    }

    /// `force` = the person pulled to refresh, or the app just came to the foreground.
    public func refresh(_ input: TrackedFlight, budget: inout UnitBudget, now: Date = Date(), force: Bool = false) async -> RefreshResult {
        budget.rollIfNeeded(now: now)
        var flight = input
        let plan = PollScheduler.plan(for: flight, now: now, budget: budget)
        let oldSnapshot = flight.snapshot
        let oldPhase = flight.phase
        let oldInboundLate = flight.inbound.map { InboundAircraftCheck.minutesLate(inbound: $0, ours: oldSnapshot, rules: rules) } ?? 0
        var spent = 0
        var polledStatus = false
        var polledPosition = false
        var newSnapshot = oldSnapshot

        // 1. Status (AeroDataBox).
        if force || PollScheduler.isDue(last: flight.lastStatusPoll, interval: plan.status, now: now) {
            if budget.canSpend(status.unitsPerCall, critical: plan.isActiveWindow || force) {
                budget.spend(status.unitsPerCall)
                spent += status.unitsPerCall
                polledStatus = true
                flight.lastStatusPoll = now
                do {
                    let legs = try await status.flights(number: flight.query.number, date: flight.query.date)
                    if let leg = flight.query.pickLeg(from: legs) {
                        newSnapshot = leg
                        flight.lastError = nil
                    } else {
                        flight.lastError = "The provider no longer lists this leg. Showing last known data."
                    }
                } catch {
                    flight.lastError = String(describing: error)
                }
            } else {
                flight.lastError = ProviderError.budgetExhausted.description
            }
        }

        // 2. Position (OpenSky), only while moving.
        if let position, let icao = newSnapshot.aircraft?.modeS,
           PollScheduler.isDue(last: flight.lastPositionPoll, interval: plan.position, now: now) {
            polledPosition = true
            flight.lastPositionPoll = now
            if let fix = try? await position.position(icao24: icao) {
                flight.position = fix
                appendTrack(&flight, fix)
            } else if let last = flight.position, last.isAirborne,
                      let lastReal = flight.track.last, now.timeIntervalSince(lastReal.time) < 10 * 60 {
                // Coverage gap: coast along the last heading, but only for 10 min past a real fix.
                flight.position = Self.deadReckoned(last, now: now)
            }
        } else if flight.position == nil, let fromProvider = newSnapshot.position {
            flight.position = fromProvider
        }

        // 3. Inbound aircraft (AeroDataBox by tail number).
        var inboundEvent: FlightEvent?
        if let reg = newSnapshot.aircraft?.registration,
           PollScheduler.isDue(last: flight.lastInboundPoll, interval: plan.inbound, now: now),
           budget.canSpend(status.unitsPerCall, critical: false) {
            budget.spend(status.unitsPerCall)
            spent += status.unitsPerCall
            flight.lastInboundPoll = now
            if let legs = try? await status.flights(registration: reg, date: flight.query.date),
               let inbound = InboundAircraftCheck.findInbound(legs: legs, for: newSnapshot) {
                flight.inbound = inbound
                inboundEvent = InboundAircraftCheck.event(
                    previousMinutesLate: oldInboundLate, inbound: inbound, ours: newSnapshot, rules: rules)
            }
        }

        // 4. Phase + events.
        let resolved = PhaseResolver.resolve(newSnapshot, position: flight.position, now: now)
        flight.phase = PhaseResolver.advance(from: oldPhase, to: resolved)
        flight.snapshot = newSnapshot

        var events = SnapshotDiffer.diff(
            old: oldSnapshot, new: newSnapshot, oldPhase: oldPhase, newPhase: flight.phase, now: now, rules: rules)
        if let inboundEvent { events.append(inboundEvent) }
        let fresh = events.filter { !flight.deliveredEventKeys.contains($0.dedupeKey) }
        flight.deliveredEventKeys.formUnion(fresh.map(\.dedupeKey))

        return RefreshResult(flight: flight, newEvents: fresh, unitsSpent: spent,
                             didPollStatus: polledStatus, didPollPosition: polledPosition)
    }

    /// Applies a GPS fix from the phone itself (you're on board, possibly with no internet).
    public func ingestDevicePosition(_ fix: LivePosition, into input: TrackedFlight, now: Date = Date()) -> RefreshResult {
        var flight = input
        let oldPhase = flight.phase
        // Only trust the phone's GPS as "the plane" once it's clearly flying.
        guard fix.isAirborne || flight.phase.isInAir else {
            return RefreshResult(flight: flight, newEvents: [], unitsSpent: 0, didPollStatus: false, didPollPosition: false)
        }
        if let current = flight.position, current.reportedAt > fix.reportedAt, current.source != .deadReckoned {
            return RefreshResult(flight: flight, newEvents: [], unitsSpent: 0, didPollStatus: false, didPollPosition: false)
        }
        flight.position = fix
        appendTrack(&flight, fix)
        flight.phase = PhaseResolver.advance(from: oldPhase, to: PhaseResolver.resolve(flight.snapshot, position: fix, now: now))
        let events = SnapshotDiffer.phaseEvents(from: oldPhase, to: flight.phase)
            .filter { !flight.deliveredEventKeys.contains($0.dedupeKey) }
        flight.deliveredEventKeys.formUnion(events.map(\.dedupeKey))
        return RefreshResult(flight: flight, newEvents: events, unitsSpent: 0, didPollStatus: false, didPollPosition: false)
    }

    static func deadReckoned(_ last: LivePosition, now: Date) -> LivePosition {
        let speedMs = Double(last.groundSpeedKt ?? 0) / 1.94384
        let moved = Geo.deadReckon(
            from: Coordinate(latitude: last.latitude, longitude: last.longitude), speedMs: speedMs,
            headingDeg: last.trackDeg ?? 0, elapsed: now.timeIntervalSince(last.reportedAt), onGround: last.onGround)
        var p = last
        p.latitude = moved.latitude
        p.longitude = moved.longitude
        p.reportedAt = now
        p.source = .deadReckoned
        return p
    }

    private func appendTrack(_ flight: inout TrackedFlight, _ fix: LivePosition) {
        if let last = flight.track.last, last.time >= fix.reportedAt { return }
        flight.track.append(TrackPoint(time: fix.reportedAt, latitude: fix.latitude, longitude: fix.longitude,
                                       altitudeFt: fix.altitudeFt, trackDeg: fix.trackDeg, onGround: fix.onGround))
        if flight.track.count > maxTrackPoints { flight.track.removeFirst(flight.track.count - maxTrackPoints) }
    }
}
