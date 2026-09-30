import XCTest
@testable import FlightCore

private let dep = utc("2026-10-05T14:30:00Z")
private func at(_ minutes: Double) -> Date { dep.addingTimeInterval(minutes * 60) }

final class PhaseResolverTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep), position: nil, now: at(-60)), .scheduled)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .boarding), position: nil, now: at(-20)), .boarding)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .gateClosed), position: nil, now: at(-5)), .boarding)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .departed), position: nil, now: at(3)), .departed)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .enRoute), position: nil, now: at(30)), .airborne)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .canceled), position: nil, now: at(0)), .canceled)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .canceledUncertain), position: nil, now: at(0)), .canceled)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .diverted), position: nil, now: at(90)), .diverted)
    }

    func testRunwayTimesAndPositionBeatStaleStatus() {
        let tookOff = makeSnapshot(departure: dep, status: .departed, depRunway: at(12))
        XCTAssertEqual(PhaseResolver.resolve(tookOff, position: nil, now: at(20)), .airborne)

        let flying = LivePosition(latitude: 33, longitude: -94, altitudeFt: 30000, onGround: false, reportedAt: at(40), source: .openSky)
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .delayed), position: flying, now: at(41)), .airborne)
        // A stale fix (older than 20 min) must not flip the phase.
        XCTAssertEqual(PhaseResolver.resolve(makeSnapshot(departure: dep, status: .delayed), position: flying, now: at(70)), .scheduled)

        let landed = makeSnapshot(departure: dep, status: .enRoute, depRunway: at(12), arrRevised: at(165), arrRunway: at(158))
        XCTAssertEqual(PhaseResolver.resolve(landed, position: nil, now: at(160)), .landed)
        XCTAssertEqual(PhaseResolver.resolve(landed, position: nil, now: at(166)), .arrived)
    }

    func testArrivedStatusAtTouchdownStillTaxiing() {
        let s = makeSnapshot(departure: dep, status: .arrived, arrRevised: at(168), arrRunway: at(158))
        XCTAssertEqual(PhaseResolver.resolve(s, position: nil, now: at(160)), .landed)
        XCTAssertEqual(PhaseResolver.resolve(s, position: nil, now: at(170)), .arrived)
    }

    func testNoPushbackGuessFromStaleEstimate() {
        // Estimated gate-out passed, provider still says Delayed: we must not claim it left.
        let s = makeSnapshot(departure: dep, status: .delayed, depRevised: at(10))
        XCTAssertEqual(PhaseResolver.resolve(s, position: nil, now: at(20)), .scheduled)
    }

    func testMonotonicAdvance() {
        XCTAssertEqual(PhaseResolver.advance(from: .airborne, to: .scheduled), .airborne)
        XCTAssertEqual(PhaseResolver.advance(from: .boarding, to: .airborne), .airborne)
        XCTAssertEqual(PhaseResolver.advance(from: .airborne, to: .diverted), .diverted)
        XCTAssertEqual(PhaseResolver.advance(from: .canceled, to: .scheduled), .scheduled, "reinstated flights come back")
        XCTAssertEqual(PhaseResolver.advance(from: nil, to: .boarding), .boarding)
    }
}

final class SnapshotDifferTests: XCTestCase {
    func diff(_ old: FlightSnapshot?, _ new: FlightSnapshot, _ oldPhase: FlightPhase? = .scheduled,
              _ newPhase: FlightPhase = .scheduled, now: Date = at(-120)) -> [FlightEvent] {
        SnapshotDiffer.diff(old: old, new: new, oldPhase: oldPhase, newPhase: newPhase, now: now)
    }

    func testFirstSightingIsSilent() {
        XCTAssertEqual(diff(nil, makeSnapshot(departure: dep), nil), [])
    }

    func testGateAssignedAndChanged() {
        let none = makeSnapshot(departure: dep, depGate: nil)
        let b12 = makeSnapshot(departure: dep, depGate: "B12")
        let b18 = makeSnapshot(departure: dep, depGate: "B18")
        XCTAssertEqual(diff(none, b12), [.gateAssigned(side: .departure, gate: "B12")])
        XCTAssertEqual(diff(b12, b18), [.gateChanged(side: .departure, from: "B12", to: "B18")])
        XCTAssertEqual(diff(b18, b18), [])
        // Gate disappearing (provider hiccup) is not an alert.
        XCTAssertEqual(diff(b18, none), [])
    }

    func testDelayThresholds() {
        let onTime = makeSnapshot(departure: dep)
        let late10 = makeSnapshot(departure: dep, depRevised: at(10))
        let late20 = makeSnapshot(departure: dep, depRevised: at(20))
        let late25 = makeSnapshot(departure: dep, depRevised: at(25))
        let late35 = makeSnapshot(departure: dep, depRevised: at(35))
        XCTAssertEqual(diff(onTime, late10), [], "under 15m is not worth a banner")
        XCTAssertEqual(diff(late10, late20), [.timeChanged(side: .departure, from: at(10), to: at(20), delayMinutes: 20)])
        XCTAssertEqual(diff(late20, late25), [], "5m wiggle while already delayed stays quiet")
        XCTAssertEqual(diff(late25, late35), [.timeChanged(side: .departure, from: at(25), to: at(35), delayMinutes: 35)])
        XCTAssertEqual(diff(late35, onTime), [.timeChanged(side: .departure, from: at(35), to: at(0), delayMinutes: 0)],
                       "recovering to on time is news")
    }

    func testEarlyDeparture() {
        let early = makeSnapshot(departure: dep, depRevised: at(-12))
        XCTAssertEqual(diff(makeSnapshot(departure: dep), early),
                       [.timeChanged(side: .departure, from: at(0), to: at(-12), delayMinutes: -12)])
    }

    func testNoDepartureTimeAlertsAfterPushback() {
        let a = makeSnapshot(departure: dep, status: .departed, depRevised: at(5))
        let b = makeSnapshot(departure: dep, status: .departed, depRevised: at(22))
        XCTAssertEqual(diff(a, b, .departed, .departed, now: at(23)), [])
    }

    func testArrivalEtaUsesWiderStepInFlight() {
        // Scheduled arrival is at(155).
        let a = makeSnapshot(departure: dep, status: .enRoute, arrRevised: at(175)) // 20m late
        let b = makeSnapshot(departure: dep, status: .enRoute, arrRevised: at(187)) // 32m late, moved 12m
        let c = makeSnapshot(departure: dep, status: .enRoute, arrRevised: at(203)) // 48m late, moved 16m
        XCTAssertEqual(diff(a, b, .airborne, .airborne, now: at(60)), [], "a 12m move is under the 15m in-flight step")
        XCTAssertEqual(diff(b, c, .airborne, .airborne, now: at(60)),
                       [.timeChanged(side: .arrival, from: at(187), to: at(203), delayMinutes: 48)])
    }

    func testPhaseMilestonesOnlyNewest() {
        let s = makeSnapshot(departure: dep)
        XCTAssertEqual(diff(s, s, .scheduled, .boarding, now: at(-20)), [.boardingStarted])
        XCTAssertEqual(diff(s, s, .boarding, .airborne, now: at(30)), [.tookOff], "skip 'pushed back' after a poll gap")
        XCTAssertEqual(diff(s, s, .airborne, .landed, now: at(160)), [.landed])
        XCTAssertEqual(diff(s, s, .landed, .arrived, now: at(170)), [.arrivedAtGate])
        XCTAssertEqual(diff(s, s, .airborne, .airborne, now: at(60)), [])
    }

    func testCancelTrumpsEverything() {
        let a = makeSnapshot(departure: dep, depGate: "B12")
        let b = makeSnapshot(departure: dep, status: .canceled, depRevised: at(90), depGate: "B20")
        XCTAssertEqual(diff(a, b, .scheduled, .canceled), [.canceled])
        XCTAssertEqual(diff(b, a, .canceled, .scheduled).first, .reinstated)
    }

    func testDiversionReportsNewAirportAndLandingAfter() {
        let a = makeSnapshot(departure: dep, status: .enRoute)
        var b = makeSnapshot(departure: dep, status: .diverted)
        b.arrival.airport = AirportRef(iata: "MKE", icao: "KMKE", name: "Milwaukee Mitchell")
        XCTAssertEqual(diff(a, b, .airborne, .diverted, now: at(120)), [.diverted(to: b.arrival.airport)])
        XCTAssertEqual(diff(b, b, .diverted, .landed, now: at(150)), [.landed], "milestones continue after a diversion")
    }

    func testBaggageBeltAndAircraftSwap() {
        let a = makeSnapshot(departure: dep, status: .arrived)
        let b = makeSnapshot(departure: dep, status: .arrived, belt: "5")
        let c = makeSnapshot(departure: dep, status: .arrived, belt: "7")
        XCTAssertEqual(diff(a, b, .arrived, .arrived, now: at(180)), [.baggageBelt(belt: "5", previous: nil)])
        XCTAssertEqual(diff(b, c, .arrived, .arrived, now: at(185)), [.baggageBelt(belt: "7", previous: "5")])
        let swapped = makeSnapshot(departure: dep, reg: "N99999")
        XCTAssertEqual(diff(makeSnapshot(departure: dep), swapped), [.aircraftChanged(from: "N37502", to: "N99999")])
    }

    func testBoardingSoonEstimateWindow() {
        let s = makeSnapshot(departure: dep, depRevised: at(10))
        XCTAssertFalse(diff(s, s, now: at(-30)).contains(.boardingSoonEstimated(departure: at(10))))
        XCTAssertTrue(diff(s, s, now: at(-20)).contains(.boardingSoonEstimated(departure: at(10))))
    }

    func testEveryEventHasAlertText() {
        let flight = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"), snapshot: makeSnapshot(departure: dep), now: at(-100))
        let all: [FlightEvent] = [
            .gateAssigned(side: .departure, gate: "B1"), .gateAssigned(side: .arrival, gate: "C1"),
            .gateChanged(side: .departure, from: "B1", to: "B2"), .terminalChanged(side: .arrival, from: "1", to: "2"),
            .timeChanged(side: .departure, from: at(0), to: at(30), delayMinutes: 30),
            .timeChanged(side: .arrival, from: at(0), to: at(-10), delayMinutes: -10),
            .timeChanged(side: .departure, from: at(30), to: at(0), delayMinutes: 0),
            .boardingStarted, .boardingSoonEstimated(departure: at(0)), .departedGate, .tookOff, .landed, .arrivedAtGate,
            .canceled, .reinstated, .diverted(to: nil), .diverted(to: AirportRef(iata: "MKE", icao: nil, name: "Milwaukee")),
            .baggageBelt(belt: "5", previous: nil), .baggageBelt(belt: "7", previous: "5"),
            .aircraftChanged(from: nil, to: "N1"), .inboundLate(inboundNumber: "UA 99", inboundETA: at(-10), minutesLate: 25),
            .inboundRecovered(inboundNumber: "UA 99"),
        ]
        for e in all {
            let c = AlertFormatter.content(for: e, flight: flight)
            XCTAssertFalse(c.title.isEmpty, "\(e)")
            XCTAssertFalse(c.body.isEmpty, "\(e)")
            XCTAssertFalse(c.title.contains("—") || c.body.contains("—"), "no em dashes in user-facing text")
        }
        XCTAssertEqual(AlertFormatter.content(for: .gateChanged(side: .departure, from: "B12", to: "B18"), flight: flight).title,
                       "Gate change: B12 → B18")
        XCTAssertEqual(AlertFormatter.content(for: .timeChanged(side: .departure, from: at(0), to: at(25), delayMinutes: 25), flight: flight).body,
                       "Now departs 9:55 AM · AUS → ORD")
        XCTAssertEqual(Set(all.map(\.dedupeKey)).count, all.count, "dedupe keys must be distinct")
    }
}

final class InboundTests: XCTestCase {
    func inboundLeg(eta: Date, status: ProviderStatus = .enRoute) -> FlightSnapshot {
        var s = makeSnapshot(departure: at(-215))
        s.number = "UA 99"
        let (a, b) = (s.departure.airport, s.arrival.airport)
        s.departure.airport = b // ORD
        s.arrival.airport = a   // AUS
        s.arrival.times = MovementTimes(scheduled: at(-50), revised: eta)
        s.status = status
        return s
    }

    func testFindsLegIntoOurDepartureAirport() {
        let ours = makeSnapshot(departure: dep)
        let earlier = inboundLeg(eta: at(-50))
        var later = makeSnapshot(departure: at(300)) // a later leg of the same tail, from AUS
        later.number = "UA 77"
        XCTAssertEqual(InboundAircraftCheck.findInbound(legs: [later, ours, earlier], for: ours)?.number, "UA 99")
        XCTAssertNil(InboundAircraftCheck.findInbound(legs: [ours, later], for: ours))
    }

    func testMinutesLateUsesTurnaround() {
        let ours = makeSnapshot(departure: dep)
        XCTAssertEqual(InboundAircraftCheck.minutesLate(inbound: inboundLeg(eta: at(-50)), ours: ours), 0)
        XCTAssertEqual(InboundAircraftCheck.minutesLate(inbound: inboundLeg(eta: at(-20)), ours: ours), 15)
        XCTAssertEqual(InboundAircraftCheck.minutesLate(inbound: inboundLeg(eta: at(-20), status: .arrived), ours: ours), 0)
        let event = InboundAircraftCheck.event(previousMinutesLate: 0, inbound: inboundLeg(eta: at(-10)), ours: ours)
        XCTAssertEqual(event, .inboundLate(inboundNumber: "UA 99", inboundETA: at(-10), minutesLate: 25))
        XCTAssertEqual(InboundAircraftCheck.event(previousMinutesLate: 25, inbound: inboundLeg(eta: at(-50)), ours: ours),
                       .inboundRecovered(inboundNumber: "UA 99"))
        XCTAssertNil(InboundAircraftCheck.event(previousMinutesLate: 25, inbound: inboundLeg(eta: at(-8)), ours: ours),
                     "27 vs 25: not a big enough change to re-alert")
    }
}

final class SchedulerAndBudgetTests: XCTestCase {
    func flight(_ phase: FlightPhase, _ snapshot: FlightSnapshot = makeSnapshot(departure: dep)) -> TrackedFlight {
        var f = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"), snapshot: snapshot, now: at(-1000))
        f.phase = phase
        return f
    }
    let budget = UnitBudget(periodStart: utc("2026-10-01T05:00:00Z"))

    func testCadenceTable() {
        XCTAssertEqual(PollScheduler.plan(for: flight(.scheduled), now: at(-48 * 60), budget: budget).status, 12 * 3600)
        XCTAssertEqual(PollScheduler.plan(for: flight(.scheduled), now: at(-10 * 60), budget: budget).status, 3 * 3600)
        let window = PollScheduler.plan(for: flight(.scheduled), now: at(-120), budget: budget)
        XCTAssertEqual(window.status, 20 * 60)
        XCTAssertEqual(window.inbound, 40 * 60)
        XCTAssertTrue(window.isActiveWindow)
        XCTAssertEqual(PollScheduler.plan(for: flight(.boarding), now: at(-30), budget: budget).status, 10 * 60)
        let air = PollScheduler.plan(for: flight(.airborne), now: at(60), budget: budget)
        XCTAssertEqual(air.status, 45 * 60)
        XCTAssertEqual(air.position, 60)
        XCTAssertNil(air.inbound)
        XCTAssertEqual(PollScheduler.plan(for: flight(.airborne), now: at(140), budget: budget).status, 15 * 60, "near arrival")
        XCTAssertEqual(PollScheduler.plan(for: flight(.landed), now: at(160), budget: budget).status, 10 * 60)
        XCTAssertEqual(PollScheduler.plan(for: flight(.canceled), now: at(0), budget: budget), .idle)
        let withBelt = flight(.arrived, makeSnapshot(departure: dep, status: .arrived, belt: "5"))
        XCTAssertEqual(PollScheduler.plan(for: withBelt, now: at(170), budget: budget), .idle)
    }

    func testLowBudgetStretchesCadence() {
        var low = budget
        low.usedUnits = 500
        XCTAssertEqual(PollScheduler.plan(for: flight(.scheduled), now: at(-120), budget: low).status, 40 * 60)
    }

    func testReserveOnlyForActiveWindow() {
        var b = budget
        b.usedUnits = 570 // 30 left, reserve is 40
        XCTAssertFalse(b.canSpend(2, critical: false))
        XCTAssertTrue(b.canSpend(2, critical: true))
        b.usedUnits = 599
        XCTAssertFalse(b.canSpend(2, critical: true))
    }

    func testBudgetRollsOverMonthly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = chicago
        var b = UnitBudget(usedUnits: 420, resetDay: 1, periodStart: utc("2026-09-01T05:00:00Z"))
        b.rollIfNeeded(now: utc("2026-09-30T12:00:00Z"), calendar: cal)
        XCTAssertEqual(b.usedUnits, 420)
        b.rollIfNeeded(now: utc("2026-10-02T12:00:00Z"), calendar: cal)
        XCTAssertEqual(b.usedUnits, 0)
        XCTAssertEqual(b.periodStart, utc("2026-10-01T05:00:00Z"))
        // Skipping several months lands on the latest period.
        b.usedUnits = 10
        b.rollIfNeeded(now: utc("2027-01-15T12:00:00Z"), calendar: cal)
        XCTAssertEqual(b.periodStart, utc("2027-01-01T06:00:00Z"))
        XCTAssertEqual(b.usedUnits, 0)
    }

    func testIsDue() {
        XCTAssertTrue(PollScheduler.isDue(last: nil, interval: 60, now: at(0)))
        XCTAssertFalse(PollScheduler.isDue(last: at(0), interval: 600, now: at(5)))
        XCTAssertTrue(PollScheduler.isDue(last: at(0), interval: 600, now: at(10)))
        XCTAssertFalse(PollScheduler.isDue(last: nil, interval: nil, now: at(0)))
    }
}

final class LiveActivityTests: XCTestCase {
    func testPayloadFitsAppleLimitWorstCase() {
        var s = makeSnapshot(departure: dep, status: .enRoute, depRevised: at(22), depRunway: at(34), arrRevised: at(180),
                             depGate: "B18-REMOTE", arrGate: "C32A", belt: "10-12")
        s.departure.airport.city = "Dallas-Fort Worth International Metroplex"
        s.arrival.airport.city = "Chicago O'Hare International Airport Area"
        var f = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"), snapshot: s, now: at(-180))
        f.phase = .airborne
        f.position = LivePosition(latitude: 35, longitude: -93, altitudeFt: 36000, groundSpeedKt: 471, reportedAt: at(60), source: .openSky)
        let attributes = LiveActivityBuilder.attributes(for: f, mapImageFile: "route-\(f.id.uuidString).png")
        let state = LiveActivityBuilder.state(for: f, now: at(60))
        let size = LiveActivityBuilder.payloadSize(attributes, state)
        XCTAssertLessThan(size, LiveActivityBuilder.payloadLimitBytes / 2, "leave headroom: \(size) bytes")
        XCTAssertEqual(attributes.route.count, 16)
    }

    func testHeadlinePerPhase() {
        let base = makeSnapshot(departure: dep, arrGate: "C32")
        var f = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"), snapshot: base, now: at(-180))
        func headline(_ phase: FlightPhase, _ now: Date) -> LiveHeadline {
            f.phase = phase
            return LiveActivityBuilder.state(for: f, now: now).headline
        }
        XCTAssertEqual(headline(.scheduled, at(-120)), .departsIn(dep))
        XCTAssertEqual(headline(.scheduled, at(-20)), .boardingSoon(dep))
        XCTAssertEqual(headline(.boarding, at(-20)), .boarding(gate: "B12"))
        XCTAssertEqual(headline(.departed, at(3)), .taxiingOut)
        XCTAssertEqual(headline(.airborne, at(60)), .landsIn(at(155)))
        XCTAssertEqual(headline(.landed, at(156)), .landedTaxiing(gate: "C32"))
        XCTAssertEqual(headline(.arrived, at(165)), .arrived(gate: "C32"))
        XCTAssertEqual(headline(.canceled, at(0)), .canceled)
        f.snapshot.arrival.baggageBelt = "5"
        XCTAssertEqual(headline(.arrived, at(170)), .baggage(belt: "5"))
    }

    func testStateToneAndStrikethrough() {
        let s = makeSnapshot(departure: dep, depRevised: at(25))
        var f = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"), snapshot: s, now: at(-180))
        f.phase = .scheduled
        let state = LiveActivityBuilder.state(for: f, now: at(-60))
        XCTAssertEqual(state.statusText, "Delayed 25m")
        XCTAssertEqual(state.tone, .minorDelay)
        XCTAssertTrue(state.departureTimeChanged)
        XCTAssertFalse(state.arrivalTimeChanged)
        XCTAssertEqual(state.progress, 0)
        XCTAssertNil(state.altitudeFt, "no altitude on the ground")
    }

    func testRouteProjectionFitsUnitSquare() {
        let aus = Coordinate(latitude: 30.1945, longitude: -97.6699)
        let ord = Coordinate(latitude: 41.9786, longitude: -87.9048)
        let pts = RouteProjection.fit(Geo.greatCircle(aus, ord, count: 16))
        for p in pts {
            XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y), "\(p)")
        }
        XCTAssertLessThan(pts.first!.y, 1)
        XCTAssertGreaterThan(pts.first!.y, pts.last!.y, "ORD is north of AUS, so higher on screen (smaller y)")
        let mid = RouteProjection.point(along: pts, fraction: 0.5).point
        XCTAssertTrue(mid.x > pts.first!.x && mid.x < pts.last!.x)
        XCTAssertEqual(RouteProjection.point(along: pts, fraction: 0).point, pts.first!)
        XCTAssertEqual(RouteProjection.point(along: pts, fraction: 1).point, pts.last!)
        // Antimeridian: HNL → a point west of the date line stays continuous.
        let wrap = RouteProjection.fit([Coordinate(latitude: 21, longitude: 179), Coordinate(latitude: 22, longitude: -179)])
        XCTAssertLessThan(abs(wrap[0].x - wrap[1].x), 0.9)
    }
}

final class EngineEndToEndTests: XCTestCase {
    /// Runs the scripted demo flight through the real engine and checks the alert story.
    func testDemoFlightProducesTheExpectedAlerts() async {
        let scenario = DemoScenario(scheduledDeparture: dep)
        let start = at(-180)
        let providers = DemoProviders(scenario: scenario, start: start)
        let engine = FlightEngine(status: providers, position: providers)
        var budget = UnitBudget(periodStart: start)
        var flight = TrackedFlight(query: scenario.query, snapshot: scenario.snapshot(at: start), now: start)
        var titles: [String] = []
        var phases: [FlightPhase] = []
        var t = start
        while t <= at(260) {
            providers.advance(to: t)
            let r = await engine.refresh(flight, budget: &budget, now: t, force: true)
            flight = r.flight
            titles += r.newEvents.filter(\.notifies).map { AlertFormatter.content(for: $0, flight: flight).title }
            if phases.last != flight.phase { phases.append(flight.phase) }
            if PollScheduler.trackingEnds(for: flight, now: t) { break }
            t = t.addingTimeInterval(60)
        }
        XCTAssertEqual(phases, [.scheduled, .boarding, .departed, .airborne, .landed, .arrived])
        let expectedInOrder = [
            "Your plane is running late",
            "Gate change: B12 → B18",
            "FT 101 delayed 25m",
            "FT 101 arrives at Gate C32",
            "FT 101 is boarding",
            "FT 101 pushed back",
            "FT 101 took off",
            "FT 101 landed",
            "FT 101 arrived",
            "Bags for FT 101: belt 5",
        ]
        var cursor = titles.startIndex
        for expected in expectedInOrder {
            guard let found = titles[cursor...].firstIndex(of: expected) else {
                XCTFail("missing or out of order: \(expected)\nall: \(titles)")
                return
            }
            cursor = titles.index(after: found)
        }
        XCTAssertEqual(Set(titles).count, titles.count, "no duplicate banners: \(titles)")
        XCTAssertFalse(flight.track.isEmpty, "positions were recorded in flight")
        XCTAssertEqual(budget.usedUnits, 0, "demo never spends real units")
    }

    func testStatusCallsPerRealFlightStayNearPlanBudget() async {
        // Unforced run at 1-minute ticks from T-3h to tracking end, counting AeroDataBox calls.
        let scenario = DemoScenario(scheduledDeparture: dep)
        let start = at(-180)
        let demo = DemoProviders(scenario: scenario, start: start)
        let counting = CountingStatus(inner: demo)
        let engine = FlightEngine(status: counting, position: demo)
        var budget = UnitBudget(periodStart: start)
        var flight = TrackedFlight(query: scenario.query, snapshot: scenario.snapshot(at: start), now: start)
        var t = start
        while t <= at(300) {
            demo.advance(to: t)
            flight = await engine.refresh(flight, budget: &budget, now: t).flight
            if PollScheduler.trackingEnds(for: flight, now: t) { break }
            t = t.addingTimeInterval(60)
        }
        let calls = counting.calls
        XCTAssertLessThanOrEqual(calls * 2, PollScheduler.estimatedUnitsPerFlight + 10, "calls: \(calls)")
        XCTAssertGreaterThanOrEqual(calls, 12, "still polling often enough to catch gate changes: \(calls)")
    }

    func testDeliveredEventsNeverRepeat() async {
        let first = makeSnapshot(departure: dep, depGate: "B12")
        let status = ScriptedStatus([makeSnapshot(departure: dep, depGate: "B18")])
        let engine = FlightEngine(status: status, position: nil)
        var budget = UnitBudget(periodStart: at(-1000))
        var flight = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05", departureAirportCode: "AUS"),
                                   snapshot: first, now: at(-120))
        let r1 = await engine.refresh(flight, budget: &budget, now: at(-100), force: true)
        XCTAssertEqual(r1.newEvents, [.gateChanged(side: .departure, from: "B12", to: "B18")])
        flight = r1.flight
        // Provider flaps back and forth: the second B18 must not alert again.
        status.legs = [first]
        flight = await engine.refresh(flight, budget: &budget, now: at(-80), force: true).flight
        status.legs = [makeSnapshot(departure: dep, depGate: "B18")]
        let r3 = await engine.refresh(flight, budget: &budget, now: at(-60), force: true)
        XCTAssertEqual(r3.newEvents, [])
        XCTAssertEqual(status.numberCalls, 3)
    }

    func testProviderErrorKeepsLastKnownData() async {
        let status = ScriptedStatus([])
        status.error = ProviderError.rateLimited(retryAfter: nil)
        let engine = FlightEngine(status: status, position: nil)
        var budget = UnitBudget(periodStart: at(-1000))
        let snap = makeSnapshot(departure: dep)
        let r = await engine.refresh(TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"), snapshot: snap, now: at(-120)),
                                     budget: &budget, now: at(-100), force: true)
        XCTAssertEqual(r.flight.snapshot, snap)
        XCTAssertNotNil(r.flight.lastError)
        XCTAssertEqual(r.newEvents, [])
    }

    func testBudgetExhaustedSkipsNonCriticalPolls() async {
        let status = ScriptedStatus([makeSnapshot(departure: dep)])
        let engine = FlightEngine(status: status, position: nil)
        var budget = UnitBudget(usedUnits: 580, periodStart: at(-1000))
        let f = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"),
                              snapshot: makeSnapshot(departure: dep, fetchedAt: at(-2000)), now: at(-2000))
        // T-10h is outside the active window: must not dip into the reserve.
        let r = await engine.refresh(f, budget: &budget, now: at(-600))
        XCTAssertEqual(status.numberCalls, 0)
        XCTAssertEqual(r.flight.lastError, ProviderError.budgetExhausted.description)
    }

    func testDevicePositionAdvancesPhaseOffline() {
        let engine = FlightEngine(status: ScriptedStatus([]), position: nil)
        var f = TrackedFlight(query: FlightQuery(number: "UA1234", date: "2026-10-05"),
                              snapshot: makeSnapshot(departure: dep, status: .departed), now: at(-100))
        f.phase = .departed
        let taxi = LivePosition(latitude: 30.19, longitude: -97.67, altitudeFt: 490, groundSpeedKt: 20, reportedAt: at(10), source: .device)
        XCTAssertEqual(engine.ingestDevicePosition(taxi, into: f, now: at(10)).flight.phase, .departed)
        let climbing = LivePosition(latitude: 30.3, longitude: -97.6, altitudeFt: 6000, groundSpeedKt: 250, reportedAt: at(15), source: .device)
        let r = engine.ingestDevicePosition(climbing, into: f, now: at(15))
        XCTAssertEqual(r.flight.phase, .airborne)
        XCTAssertEqual(r.newEvents, [.tookOff])
        XCTAssertEqual(r.flight.track.count, 1)
    }
}

final class CountingStatus: FlightStatusProvider, @unchecked Sendable {
    let inner: FlightStatusProvider
    private(set) var calls = 0
    let unitsPerCall = 2
    init(inner: FlightStatusProvider) { self.inner = inner }
    func flights(number: String, date: String) async throws -> [FlightSnapshot] {
        calls += 1
        return try await inner.flights(number: number, date: date)
    }
    func flights(registration: String, date: String) async throws -> [FlightSnapshot] {
        calls += 1
        return try await inner.flights(registration: registration, date: date)
    }
}
