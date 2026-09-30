import ActivityKit
import FlightCore
import SwiftUI
import WidgetKit

/// Lock screen + Dynamic Island for one flight. Layout follows Flighty's pattern:
/// status on top, big airport codes and times, a route with the plane, and one
/// phase-specific line at the bottom that counts down on its own.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            LockScreenView(info: context.attributes.info, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DeepLink.flight(context.attributes.info.flightID))
        } dynamicIsland: { context in
            let info = context.attributes.info
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedEndpoint(code: info.departureCode, time: state.departureBest,
                                     zoneID: info.departureTimeZoneID, gate: state.departureGate, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedEndpoint(code: state.arrivalCodeOverride ?? info.arrivalCode, time: state.arrivalBest,
                                     zoneID: info.arrivalTimeZoneID, gate: state.arrivalGate, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 6) {
                        Text(info.number).font(.subheadline.weight(.semibold))
                        StatusPill(text: state.statusText, tone: state.tone)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        FlightProgressBar(state: state)
                        HeadlineView(state: state, info: info)
                            .font(.caption.weight(.medium))
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: state.phase.symbol).foregroundStyle(state.tone.color)
                    Text(compactLeadingText(info: info, state: state))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
            } compactTrailing: {
                if let target = state.countdownTarget {
                    CountdownText(target: target)
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: 52)
                        .foregroundStyle(state.tone.color)
                } else {
                    Text(compactTrailingText(state: state))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.tone.color)
                }
            } minimal: {
                if let window = state.flightWindow, state.phase.isInAir {
                    ProgressView(timerInterval: window, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "airplane").font(.system(size: 8))
                    }
                    .progressViewStyle(.circular)
                    .tint(state.tone.color)
                } else {
                    Image(systemName: state.phase.symbol).foregroundStyle(state.tone.color)
                }
            }
            .widgetURL(DeepLink.flight(info.flightID))
            .keylineTint(state.tone.color)
        }
    }

    /// Before departure: departure gate. In the air: destination. After: belt or arrival gate.
    private func compactLeadingText(info: LiveActivityStatic, state: LiveActivityState) -> String {
        switch state.phase {
        case .scheduled, .boarding: return state.departureGate ?? info.departureCode
        case .departed, .airborne, .diverted: return state.arrivalCodeOverride ?? info.arrivalCode
        case .landed, .arrived: return state.baggageBelt.map { "Belt \($0)" } ?? state.arrivalGate ?? info.arrivalCode
        case .canceled: return info.number
        }
    }

    private func compactTrailingText(state: LiveActivityState) -> String {
        switch state.phase {
        case .canceled: return "Canceled"
        case .boarding: return "Boarding"
        case .departed: return "Taxi"
        case .landed: return "Landed"
        case .arrived: return state.arrivalGate.map { "Gate \($0)" } ?? "Arrived"
        default: return state.statusText
        }
    }
}

extension FlightPhase {
    var symbol: String {
        switch self {
        case .scheduled: return "airplane.departure"
        case .boarding: return "figure.walk"
        case .departed: return "airplane.departure"
        case .airborne: return "airplane"
        case .landed: return "airplane.arrival"
        case .arrived: return "suitcase.rolling"
        case .diverted: return "arrow.triangle.branch"
        case .canceled: return "xmark.octagon"
        }
    }
}

private struct ExpandedEndpoint: View {
    var code: String
    var time: Date?
    var zoneID: String?
    var gate: String?
    var alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(code).font(.title3.weight(.bold)).monospaced()
            Text(FlightFormat.localTime(time, timeZone: zoneID.flatMap(TimeZone.init(identifier:)) ?? .current))
                .font(.caption.weight(.semibold))
            Text("Gate \(gate ?? "TBD")").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
