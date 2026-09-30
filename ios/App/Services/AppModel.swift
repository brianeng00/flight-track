import BackgroundTasks
import FlightCore
import Foundation
import Observation
import os
import UIKit

/// Owns app state and runs tracking. Free-account mode: this process does all polling,
/// alerting and Live Activity updates; the keep-alive keeps it running while locked.
@MainActor
@Observable
final class AppModel {
    // MARK: State the UI reads

    private(set) var flights: [TrackedFlight] = []
    private(set) var budget: UnitBudget
    private(set) var settings: AppSettings
    private(set) var heartbeat: HeartbeatLog
    var selectedFlightID: UUID?
    var lastError: String?
    private(set) var isTicking = false
    private(set) var demo: DemoRun?

    var isConfigured: Bool { AppConfig.isConfigured }
    var activeFlights: [TrackedFlight] { flights.filter { !$0.isArchived && !isFinished($0) } }
    var pastFlights: [TrackedFlight] { flights.filter { $0.isArchived || isFinished($0) } }
    var flightsLeftThisMonth: Int { budget.remaining / PollScheduler.estimatedUnitsPerFlight }
    var keepAliveRunning: Bool { keepAlive.isRunning }
    var liveActivitiesEnabled: Bool { liveActivities.areActivitiesEnabled }

    // MARK: Services

    private let store = FlightStore()
    private let heartbeatStore = HeartbeatStore()
    let notifier = LocalNotifier()
    private let liveActivities: LiveActivityManager
    private let keepAlive: KeepAliveLocation
    private let engine: FlightEngine?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Flights whose Live Activity the person ended themselves: don't auto-restart.
    @ObservationIgnored private var stoppedByUser: Set<UUID> = []
    @ObservationIgnored private var pendingStart: UUID?
    @ObservationIgnored private var isForeground = true
    private let log = Logger(subsystem: AppConfig.bundleID, category: "AppModel")

    /// Seconds between loop passes. The engine decides which polls are actually due.
    static let loopInterval: TimeInterval = 30

    init() {
        liveActivities = LiveActivityManager()
        keepAlive = KeepAliveLocation()
        // Local instances: `self` isn't usable until every stored property is set.
        let stored = FlightStore().load()
        flights = stored.flights
        budget = stored.budget
        settings = stored.settings
        heartbeat = HeartbeatStore().load()
        if let marketplace = AppConfig.aeroDataBoxMarketplace {
            engine = FlightEngine(status: AeroDataBoxClient(marketplace: marketplace),
                                  position: OpenSkyClient(credentials: AppConfig.openSkyCredentials))
        } else {
            engine = nil
        }
        keepAlive.onFix = { [weak self] fix in self?.handleDeviceFix(fix) }
        notifier.onOpen = { [weak self] kind, id in self?.handleNotificationOpen(kind: kind, flightID: id) }
        if settings.remindBeforeProfileExpiry, let expiry = AppConfig.profileExpiry {
            notifier.scheduleReinstallReminder(expiry: expiry)
        }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        persist()
        if !settings.keepAliveEnabled { keepAlive.stop() }
        if settings.remindBeforeProfileExpiry, let expiry = AppConfig.profileExpiry {
            notifier.scheduleReinstallReminder(expiry: expiry)
        }
    }

    // MARK: Adding and removing flights

    func search(number: String, date: Date) async throws -> [FlightSnapshot] {
        guard let engine else { throw ProviderError.missingCredentials("AeroDataBox key (see ios/README.md)") }
        var b = budget
        defer { budget = b; persist() }
        return try await engine.search(number: number, date: Self.dayString(date), budget: &b)
    }

    func add(_ leg: FlightSnapshot, searchedNumber: String, date: Date) async {
        let query = FlightQuery(number: searchedNumber, date: Self.dayString(date),
                                departureAirportCode: leg.departure.airport.iata ?? leg.departure.airport.icao,
                                scheduledDeparture: leg.departure.times.scheduled)
        let flight = TrackedFlight(query: query, snapshot: leg)
        flights.append(flight)
        flights.sort { ($0.snapshot.departure.times.scheduled ?? .distantFuture) < ($1.snapshot.departure.times.scheduled ?? .distantFuture) }
        persist()
        _ = await notifier.requestAuthorization()
        if let departure = leg.departure.times.bestGate {
            notifier.scheduleStartReminder(for: flight, at: departure.addingTimeInterval(-PollScheduler.activeWindowLead))
        }
        if isInActiveWindow(flight) { await startLiveTracking(flight.id) }
        ensureLoop()
    }

    func remove(_ id: UUID) async {
        await liveActivities.end(flightID: id, finalState: nil, linger: 0)
        notifier.cancelReminders(for: id)
        MapSnapshotRenderer.delete(for: id)
        flights.removeAll { $0.id == id }
        stoppedByUser.remove(id)
        persist()
        stopKeepAliveIfIdle()
    }

    // MARK: Live tracking

    func isLive(_ id: UUID) -> Bool { liveActivities.isRunning(id) }

    /// Foreground only (ActivityKit rule). Renders the map, starts the Live Activity and keep-alive.
    func startLiveTracking(_ id: UUID) async {
        guard let index = flights.firstIndex(where: { $0.id == id }) else { return }
        stoppedByUser.remove(id)
        var flight = flights[index]
        let now = Date()
        var map: MapSnapshotRenderer.Output?
        if settings.mapOnLiveActivity { map = await MapSnapshotRenderer.render(for: flight) }
        let attributes = LiveActivityBuilder.attributes(for: flight, route: map?.route, mapImageFile: map?.fileName)
        flight.liveActivityID = liveActivities.start(attributes: attributes, state: LiveActivityBuilder.state(for: flight, now: now), now: now)
        if flight.liveActivityID == nil {
            lastError = liveActivitiesEnabled
                ? "Couldn't start the Live Activity. Try again with the app open."
                : "Live Activities are off. Settings > FlightTrack > Live Activities."
        }
        if let i = flights.firstIndex(where: { $0.id == id }) { flights[i] = flight }
        notifier.cancelReminders(for: id)
        persist()
        if settings.keepAliveEnabled { keepAlive.start() }
        ensureLoop()
    }

    func stopLiveTracking(_ id: UUID) async {
        stoppedByUser.insert(id)
        if let flight = flights.first(where: { $0.id == id }) {
            await liveActivities.end(flightID: id, finalState: LiveActivityBuilder.state(for: flight, now: Date()), linger: 0)
        }
        stopKeepAliveIfIdle()
    }

    // MARK: The loop

    /// Runs while anything needs attention: an active window, or the demo.
    func ensureLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                if !self.needsLoop { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.loopInterval * 1_000_000_000))
            }
            self?.loopTask = nil
        }
    }

    private var needsLoop: Bool {
        isForeground || flights.contains { liveActivities.isRunning($0.id) || isInActiveWindow($0) }
    }

    /// One pass over every flight: poll what's due, alert, update Live Activities, end finished ones.
    func tick(force: Bool = false, only id: UUID? = nil) async {
        guard let engine, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        let now = Date()
        heartbeat.record(at: now, inBackground: !isForeground)
        heartbeatStore.save(heartbeat)

        for flight in flights where !flight.isArchived && (id == nil || flight.id == id) {
            var b = budget
            let result = await engine.refresh(flight, budget: &b, now: now, force: force)
            budget = b
            await apply(result.flight, events: result.newEvents, now: now)
        }
        persist()
        keepAlive.setInFlight(flights.contains { $0.phase.isInAir && liveActivities.isRunning($0.id) })
        stopKeepAliveIfIdle()
    }

    private func apply(_ updated: TrackedFlight, events: [FlightEvent], now: Date) async {
        guard let i = flights.firstIndex(where: { $0.id == updated.id }) else { return }
        flights[i] = updated
        for event in events where event.notifies {
            notifier.post(AlertFormatter.content(for: event, flight: updated), flightID: updated.id, eventKey: event.dedupeKey)
        }
        if events.contains(where: { if case .timeChanged(.departure, _, _, _) = $0 { return true }; return false }),
           let departure = updated.snapshot.departure.times.bestGate, !liveActivities.isRunning(updated.id) {
            notifier.scheduleStartReminder(for: updated, at: departure.addingTimeInterval(-PollScheduler.activeWindowLead))
        }
        guard liveActivities.isRunning(updated.id) else { return }
        if PollScheduler.trackingEnds(for: updated, now: now) {
            await liveActivities.end(flightID: updated.id, finalState: LiveActivityBuilder.state(for: updated, now: now))
        } else {
            await liveActivities.update(flightID: updated.id, state: LiveActivityBuilder.state(for: updated, now: now), now: now)
        }
    }

    private func handleDeviceFix(_ fix: LivePosition) {
        guard let engine else { return }
        for flight in flights where liveActivities.isRunning(flight.id) && flight.phase >= .departed && !flight.phase.isTerminal {
            let result = engine.ingestDevicePosition(fix, into: flight)
            guard result.flight != flight else { continue }
            Task { await self.apply(result.flight, events: result.newEvents, now: Date()) }
        }
    }

    private func stopKeepAliveIfIdle() {
        let anyLive = flights.contains { liveActivities.isRunning($0.id) } || demo != nil
        if !anyLive { keepAlive.stop() }
    }

    // MARK: App lifecycle

    func sceneBecameActive() async {
        isForeground = true
        if let id = pendingStart {
            pendingStart = nil
            await startLiveTracking(id)
        }
        // Auto-start for flights that entered their window while we were closed.
        for flight in flights where liveActivities.wasDismissedByUser(flight.id) { stoppedByUser.insert(flight.id) }
        for flight in flights where isInActiveWindow(flight) && !liveActivities.isRunning(flight.id) && !stoppedByUser.contains(flight.id) {
            await startLiveTracking(flight.id)
        }
        let stale = flights.contains { ($0.lastStatusPoll ?? .distantPast) < Date().addingTimeInterval(-5 * 60) && isInActiveWindow($0) }
        await tick(force: stale)
        ensureLoop()
    }

    func sceneEnteredBackground() {
        isForeground = false
        scheduleBackgroundRefresh()
    }

    /// BGAppRefreshTask: iOS runs this when it feels like it. Useful before the active window.
    func backgroundRefresh() async {
        await tick()
        scheduleBackgroundRefresh()
    }

    private func scheduleBackgroundRefresh() {
        guard flights.contains(where: { !$0.isArchived && !isFinished($0) }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch { log.error("BG submit failed: \(error.localizedDescription)") }
    }

    func handle(url: URL) {
        if let id = DeepLink.flightID(from: url) { selectedFlightID = id }
    }

    private func handleNotificationOpen(kind: LocalNotifier.Kind, flightID: UUID?) {
        if let flightID { selectedFlightID = flightID }
        if kind == .startTracking, let flightID {
            // Tapping brings the app forward; start once the scene is active.
            pendingStart = flightID
            if UIApplication.shared.applicationState == .active {
                Task { await self.sceneBecameActive() }
            }
        }
    }

    // MARK: Demo ("Simulate a flight")

    struct DemoRun {
        var flight: TrackedFlight
        var providers: DemoProviders
        var speed: Double
        var startedAt: Date
    }

    var demoFlight: TrackedFlight? { demo?.flight }

    /// Plays the scripted FT 101 through the real engine, Live Activity and notifications.
    /// `speed` 1 = real time (the 4-hour keep-alive endurance test); 60 = one flight minute per second.
    func startDemo(speed: Double) async {
        await stopDemo()
        let realNow = Date()
        let departure = realNow.addingTimeInterval(3 * 3600)
        let scenario = DemoScenario(scheduledDeparture: departure)
        let providers = DemoProviders(scenario: scenario, start: realNow)
        let flight = TrackedFlight(query: scenario.query, snapshot: scenario.snapshot(at: realNow), now: realNow)
        demo = DemoRun(flight: flight, providers: providers, speed: speed, startedAt: realNow)
        _ = await notifier.requestAuthorization()
        let attributes = LiveActivityBuilder.attributes(for: flight)
        liveActivities.start(attributes: attributes, state: LiveActivityBuilder.state(for: flight, now: realNow), now: realNow)
        if settings.keepAliveEnabled { keepAlive.start() }
        Task { await self.runDemoLoop() }
    }

    func stopDemo() async {
        guard let run = demo else { return }
        demo = nil
        await liveActivities.end(flightID: run.flight.id, finalState: nil, linger: 0)
        stopKeepAliveIfIdle()
    }

    private func runDemoLoop() async {
        guard let initial = demo else { return }
        let engine = FlightEngine(status: initial.providers, position: initial.providers)
        var scratch = UnitBudget(monthlyUnits: .max / 2, periodStart: Date())
        let realStep: TimeInterval = initial.speed <= 1 ? Self.loopInterval : 1
        while let run = demo, run.flight.id == initial.flight.id {
            let realNow = Date()
            let virtualNow = run.startedAt.addingTimeInterval(realNow.timeIntervalSince(run.startedAt) * run.speed)
            run.providers.advance(to: virtualNow)
            heartbeat.record(at: realNow, inBackground: !isForeground)
            let result = await engine.refresh(run.flight, budget: &scratch, now: virtualNow, force: true)
            guard demo?.flight.id == run.flight.id else { return }
            demo?.flight = result.flight
            for event in result.newEvents where event.notifies {
                var content = AlertFormatter.content(for: event, flight: result.flight)
                content.title = "Demo · " + content.title
                notifier.post(content, flightID: result.flight.id, eventKey: event.dedupeKey)
            }
            let state = LiveActivityBuilder.state(for: result.flight, now: virtualNow).shifted(by: realNow.timeIntervalSince(virtualNow))
            if PollScheduler.trackingEnds(for: result.flight, now: virtualNow) {
                await liveActivities.end(flightID: run.flight.id, finalState: state)
                demo = nil
                heartbeatStore.save(heartbeat)
                stopKeepAliveIfIdle()
                return
            }
            await liveActivities.update(flightID: run.flight.id, state: state, now: realNow)
            if Int(realNow.timeIntervalSince1970) % 30 == 0 { heartbeatStore.save(heartbeat) }
            try? await Task.sleep(nanoseconds: UInt64(realStep * 1_000_000_000))
        }
    }

    func clearHeartbeat() {
        heartbeat.clear()
        heartbeatStore.save(heartbeat)
    }

    // MARK: Helpers

    func flight(_ id: UUID?) -> TrackedFlight? {
        guard let id else { return nil }
        if demo?.flight.id == id { return demo?.flight }
        return flights.first { $0.id == id }
    }

    func isInActiveWindow(_ flight: TrackedFlight) -> Bool {
        guard !flight.isArchived, !flight.phase.isTerminal else { return false }
        if flight.phase >= .departed { return true }
        guard let departure = flight.snapshot.departure.times.bestGate else { return false }
        return departure.timeIntervalSinceNow <= PollScheduler.activeWindowLead
    }

    private func isFinished(_ flight: TrackedFlight) -> Bool {
        PollScheduler.trackingEnds(for: flight, now: Date())
            || (flight.phase == .arrived && PollScheduler.plan(for: flight, now: Date(), budget: budget) == .idle)
    }

    private func persist() {
        store.save(StoredState(flights: flights, budget: budget, settings: settings))
    }

    static func dayString(_ date: Date) -> String {
        FlightDate.dayString(date, in: .current)
    }
}
