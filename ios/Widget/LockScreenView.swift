import FlightCore
import SwiftUI
import UIKit
import WidgetKit

/// The lock-screen card.
struct LockScreenView: View {
    var info: LiveActivityStatic
    var state: LiveActivityState
    var isStale: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Top row: flight + status.
            HStack(spacing: 8) {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.tone.color)
                Text(info.number).font(.headline)
                Spacer()
                if isStale {
                    Label("Not updated", systemImage: "exclamationmark.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                StatusPill(text: state.statusText, tone: state.tone)
            }

            // Middle: departure | route | arrival.
            HStack(alignment: .center, spacing: 8) {
                Endpoint(code: info.departureCode, time: state.departureBest, scheduled: state.departureScheduled,
                         changed: state.departureTimeChanged, zoneID: info.departureTimeZoneID,
                         terminal: state.departureTerminal, gate: state.departureGate, alignment: .leading)
                RouteArcView(route: info.route, progress: state.progress, tint: state.tone.color,
                             showPlane: state.phase >= .departed, mapImage: mapImage)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Endpoint(code: state.arrivalCodeOverride ?? info.arrivalCode, time: state.arrivalBest, scheduled: state.arrivalScheduled,
                         changed: state.arrivalTimeChanged, zoneID: info.arrivalTimeZoneID,
                         terminal: state.arrivalTerminal, gate: state.arrivalGate, alignment: .trailing)
            }

            // Self-updating progress while flying; keeps moving with no Wi-Fi on board.
            FlightProgressBar(state: state)

            // Bottom: one phase-specific line.
            HeadlineView(state: state, info: info)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .foregroundStyle(.white)
    }

    /// The pre-rendered route map from the App Group, if the app rendered one.
    private var mapImage: Image? {
        guard let file = info.mapImageFile,
              let ui = UIImage(contentsOfFile: AppGroup.mapImageURL(named: file).path) else { return nil }
        return Image(uiImage: ui)
    }
}

private struct Endpoint: View {
    var code: String
    var time: Date?
    var scheduled: Date?
    var changed: Bool
    var zoneID: String?
    var terminal: String?
    var gate: String?
    var alignment: HorizontalAlignment

    var body: some View {
        let zone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        VStack(alignment: alignment, spacing: 1) {
            Text(code).font(.title2.weight(.heavy)).monospaced()
            Text(FlightFormat.localTime(time, timeZone: zone)).font(.caption.weight(.bold))
            if changed {
                Text(FlightFormat.localTime(scheduled, timeZone: zone))
                    .font(.caption2)
                    .strikethrough()
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(gateText).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
        }
        .frame(minWidth: 64, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var gateText: String {
        let gate = "Gate \(self.gate ?? "TBD")"
        guard let terminal else { return gate }
        return "T\(terminal) · \(gate)"
    }
}

/// Linear progress between takeoff and landing that the system animates by itself.
struct FlightProgressBar: View {
    var state: LiveActivityState

    var body: some View {
        if let window = state.flightWindow, state.phase.isInAir {
            ProgressView(timerInterval: window, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(state.tone.color)
        } else {
            ProgressView(value: min(max(state.progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(state.tone.color)
        }
    }
}

/// "Departs in 1:12:03 · Gate C14", "Lands in 0:42:10 · 36,000 ft · 470 kt", "Bags on belt 7", ...
struct HeadlineView: View {
    var state: LiveActivityState
    var info: LiveActivityStatic

    var body: some View {
        HStack(spacing: 4) {
            switch state.headline {
            case .departsIn(let d):
                Text("Departs in")
                CountdownText(target: d)
                Text("· Gate \(state.departureGate ?? "TBD")")
            case .boardingSoon(let d):
                Text("Boarding soon (est.) · departs in")
                CountdownText(target: d)
            case .boarding(let gate):
                Text("Boarding now · Gate \(gate ?? "TBD")")
            case .taxiingOut:
                Text("Taxiing to the runway")
            case .landsIn(let d):
                Text("Lands in")
                CountdownText(target: d)
                if let alt = state.altitudeFt, let kt = state.groundSpeedKt {
                    Text("· \(alt.formatted()) ft · \(kt) kt").lineLimit(1)
                }
            case .landedTaxiing(let gate):
                Text("Landed · taxiing to Gate \(gate ?? "TBD")")
            case .baggage(let belt):
                Image(systemName: "suitcase.rolling.fill")
                Text("Bags on belt \(belt)")
            case .arrived(let gate):
                Text("Arrived at Gate \(gate ?? "TBD") · belt TBD")
            case .canceled:
                Text("Flight canceled. Check the airline app to rebook.")
            case .diverted(let code):
                Text("Diverted to \(code ?? "another airport")")
            case .scheduled:
                Text("Scheduled")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
