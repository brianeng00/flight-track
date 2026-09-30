import ActivityKit
import FlightCore
import Foundation
import os

/// Starts, updates and ends the lock-screen Live Activity for a flight.
/// Free-account mode: `pushType: nil`, so every update comes from this process.
@MainActor
final class LiveActivityManager {
    private let log = Logger(subsystem: AppConfig.bundleID, category: "LiveActivity")
    /// Last state we sent per flight, so identical polls don't re-render the widget.
    private var lastSent: [UUID: LiveActivityState] = [:]

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func activity(for flightID: UUID) -> Activity<FlightActivityAttributes>? {
        Activity<FlightActivityAttributes>.activities.first { $0.attributes.info.flightID == flightID }
    }

    func isRunning(_ flightID: UUID) -> Bool {
        guard let a = activity(for: flightID) else { return false }
        return a.activityState == .active || a.activityState == .stale
    }

    /// Must be called while the app is in the foreground (ActivityKit rule).
    /// Returns the activity id, or nil with the reason logged.
    @discardableResult
    func start(attributes: LiveActivityStatic, state: LiveActivityState, now: Date) -> String? {
        if let existing = activity(for: attributes.flightID) { return existing.id }
        guard areActivitiesEnabled else {
            log.error("Live Activities are turned off in Settings")
            return nil
        }
        let size = LiveActivityBuilder.payloadSize(attributes, state)
        guard size < LiveActivityBuilder.payloadLimitBytes else {
            log.error("Payload \(size) bytes is over Apple's 4 KB limit")
            return nil
        }
        do {
            let activity = try Activity.request(
                attributes: FlightActivityAttributes(info: attributes),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(LiveActivityBuilder.staleAfter)),
                pushType: nil)
            lastSent[attributes.flightID] = state
            return activity.id
        } catch {
            log.error("Activity.request failed: \(error.localizedDescription)")
            return nil
        }
    }

    func update(flightID: UUID, state: LiveActivityState, now: Date) async {
        guard let activity = activity(for: flightID) else { return }
        // Skip re-sending the same content, but always push the stale date forward on real polls.
        var comparable = state
        comparable.updatedAt = lastSent[flightID]?.updatedAt ?? state.updatedAt
        if comparable == lastSent[flightID], activity.activityState != .stale,
           now.timeIntervalSince(lastSent[flightID]?.updatedAt ?? .distantPast) < 5 * 60 {
            return
        }
        lastSent[flightID] = state
        await activity.update(ActivityContent(state: state, staleDate: now.addingTimeInterval(LiveActivityBuilder.staleAfter)))
    }

    /// Ends with the final state visible for `linger`, then the system removes it.
    func end(flightID: UUID, finalState: LiveActivityState?, linger: TimeInterval = 20 * 60) async {
        guard let activity = activity(for: flightID) else { return }
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(linger)))
        lastSent[flightID] = nil
    }

    func endAll() async {
        for activity in Activity<FlightActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        lastSent.removeAll()
    }
}
