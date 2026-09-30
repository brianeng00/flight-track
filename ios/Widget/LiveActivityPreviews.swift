#if DEBUG
import FlightCore
import SwiftUI
import WidgetKit

/// Xcode canvas previews for every phase, built with the same FlightCore builders the app uses.
private enum PreviewData {
    static let now = Date()
    static let scenario = DemoScenario(scheduledDeparture: now.addingTimeInterval(90 * 60))

    static func flight(at minutes: Double) -> (LiveActivityStatic, LiveActivityState) {
        let virtual = scenario.scheduledDeparture.addingTimeInterval(minutes * 60)
        var f = TrackedFlight(query: scenario.query, snapshot: scenario.snapshot(at: virtual), now: virtual)
        f.position = scenario.position(at: virtual)
        f.phase = PhaseResolver.resolve(f.snapshot, position: f.position, now: virtual)
        let state = LiveActivityBuilder.state(for: f, now: virtual).shifted(by: now.timeIntervalSince(virtual))
        return (LiveActivityBuilder.attributes(for: f), state)
    }

    static var attributes: FlightActivityAttributes { FlightActivityAttributes(info: flight(at: -150).0) }
    static var onTime: LiveActivityState { flight(at: -150).1 }
    static var delayed: LiveActivityState { flight(at: -60).1 }
    static var boarding: LiveActivityState { flight(at: -5).1 }
    static var airborne: LiveActivityState { flight(at: 100).1 }
    static var bags: LiveActivityState { flight(at: 205).1 }
    static var canceled: LiveActivityState {
        var s = flight(at: -60).1
        s.phase = .canceled
        s.statusText = "Canceled"
        s.tone = .canceled
        s.headline = .canceled
        return s
    }
}

#Preview("Lock Screen", as: .content, using: PreviewData.attributes) {
    FlightLiveActivity()
} contentStates: {
    PreviewData.onTime
    PreviewData.delayed
    PreviewData.boarding
    PreviewData.airborne
    PreviewData.bags
    PreviewData.canceled
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: PreviewData.attributes) {
    FlightLiveActivity()
} contentStates: {
    PreviewData.delayed
    PreviewData.airborne
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: PreviewData.attributes) {
    FlightLiveActivity()
} contentStates: {
    PreviewData.delayed
    PreviewData.airborne
    PreviewData.bags
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: PreviewData.attributes) {
    FlightLiveActivity()
} contentStates: {
    PreviewData.airborne
}
#endif
