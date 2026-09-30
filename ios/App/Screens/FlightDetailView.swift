import Charts
import FlightCore
import MapKit
import SwiftUI

/// FlightAware-depth detail: map with flown track, the four clocks, gates, aircraft,
/// inbound plane, altitude and speed charts.
struct FlightDetailView: View {
    @Environment(AppModel.self) private var model
    var flightID: UUID

    var body: some View {
        if let flight = model.flight(flightID) {
            ScrollView {
                VStack(spacing: 16) {
                    HeaderCard(flight: flight)
                    FlightMapView(flight: flight)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    TimesCard(flight: flight)
                    GatesCard(flight: flight)
                    if flight.track.count >= 3 { ProfileCharts(track: flight.track) }
                    if let inbound = flight.inbound { InboundCard(inbound: inbound, ours: flight.snapshot) }
                    AircraftCard(flight: flight)
                    LiveControls(flight: flight)
                    FreshnessFooter(flight: flight)
                }
                .padding()
            }
            .navigationTitle(flight.snapshot.number)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.tick(force: true, only: flightID) }
        } else {
            ContentUnavailableView("Flight removed", systemImage: "airplane")
        }
    }
}

private struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct HeaderCard: View {
    var flight: TrackedFlight

    var body: some View {
        let s = flight.snapshot
        let delay = FlightFormat.relevantDelay(flight)
        let tone = FlightFormat.tone(delayMinutes: delay, phase: flight.phase)
        Card(title: nil) {
            HStack {
                VStack(alignment: .leading) {
                    Text(s.airlineName ?? s.number).font(.subheadline).foregroundStyle(.secondary)
                    Text(s.number).font(.title.weight(.bold))
                }
                Spacer()
                StatusPill(text: FlightFormat.statusText(delayMinutes: delay, phase: flight.phase), tone: tone)
            }
            HStack(alignment: .firstTextBaseline) {
                EndpointColumn(code: s.departure.airport.code, time: s.departure.times.bestGate,
                               scheduled: s.departure.times.scheduled, zone: s.departure.airport.timeZone, alignment: .leading)
                Spacer()
                EndpointColumn(code: s.arrival.airport.code, time: s.arrival.times.bestGate,
                               scheduled: s.arrival.times.scheduled, zone: s.arrival.airport.timeZone, alignment: .trailing)
            }
            ProgressView(value: flight.progress(now: Date()))
                .tint(tone.color)
            HStack {
                Text(s.departure.airport.city ?? s.departure.airport.name)
                Spacer()
                Text(phaseLine(flight))
                Spacer()
                Text(s.arrival.airport.city ?? s.arrival.airport.name)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func phaseLine(_ f: TrackedFlight) -> String {
        let s = f.snapshot
        switch f.phase {
        case .scheduled:
            guard let d = s.departure.times.bestGate else { return "Scheduled" }
            return d > Date() ? "Departs in \(FlightFormat.duration(d.timeIntervalSinceNow))" : "Awaiting departure"
        case .boarding: return s.status == .gateClosed ? "Gate closed" : "Boarding"
        case .departed: return "Taxiing"
        case .airborne:
            guard let eta = s.arrival.times.runway ?? s.arrival.times.bestGate else { return "In the air" }
            return "Lands in \(FlightFormat.duration(eta.timeIntervalSinceNow))"
        case .landed: return "Landed, taxiing"
        case .arrived: return "Arrived"
        case .canceled: return "Canceled"
        case .diverted: return "Diverted to \(s.arrival.airport.code)"
        }
    }
}

private struct FlightMapView: View {
    var flight: TrackedFlight

    var body: some View {
        let dep = flight.departureCoordinate
        let arr = flight.arrivalCoordinate
        Map(initialPosition: .automatic) {
            if let dep, let arr {
                MapPolyline(coordinates: Geo.greatCircle(dep, arr, count: 64).map(\.clLocation))
                    .stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                Marker(flight.snapshot.departure.airport.code, systemImage: "airplane.departure", coordinate: dep.clLocation)
                    .tint(.green)
                Marker(flight.snapshot.arrival.airport.code, systemImage: "airplane.arrival", coordinate: arr.clLocation)
                    .tint(.blue)
            }
            if flight.track.count >= 2 {
                MapPolyline(coordinates: flight.track.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(.cyan, lineWidth: 3)
            }
            if let p = flight.position, flight.phase.isInAir {
                Annotation(flight.snapshot.number, coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                    Image(systemName: "airplane")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.yellow)
                        .rotationEffect(.degrees((p.trackDeg ?? 0) - 90))
                        .shadow(radius: 3)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
    }
}

private extension Coordinate {
    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Scheduled / estimated-or-actual for each of the four milestones, like FlightAware.
private struct TimesCard: View {
    var flight: TrackedFlight

    var body: some View {
        let d = flight.snapshot.departure, a = flight.snapshot.arrival
        let dz = d.airport.timeZone, az = a.airport.timeZone
        Card(title: "Times (local)") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Scheduled").font(.caption).foregroundStyle(.secondary)
                    Text("Estimated / actual").font(.caption).foregroundStyle(.secondary)
                }
                row("Gate departure", d.times.scheduled, d.times.revised ?? d.times.predicted, dz, actual: flight.phase >= .departed)
                row("Takeoff", nil, d.times.runway, dz, actual: flight.phase >= .airborne)
                row("Landing", nil, a.times.runway, az, actual: flight.phase >= .landed)
                row("Gate arrival", a.times.scheduled, a.times.revised ?? a.times.predicted, az, actual: flight.phase >= .arrived)
            }
            if let scheduled = d.times.scheduled, let arrival = a.times.scheduled {
                Text("Scheduled block time \(FlightFormat.duration(arrival.timeIntervalSince(scheduled)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let out = d.times.revised, let takeoff = d.times.runway, takeoff > out {
                Text("Taxi out \(FlightFormat.duration(takeoff.timeIntervalSince(out)))").font(.caption).foregroundStyle(.secondary)
            }
            if let landing = a.times.runway, let gateIn = a.times.revised, gateIn > landing, flight.phase >= .arrived {
                Text("Taxi in \(FlightFormat.duration(gateIn.timeIntervalSince(landing)))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ scheduled: Date?, _ best: Date?, _ zone: TimeZone, actual: Bool) -> some View {
        GridRow {
            Text(label).font(.subheadline)
            Text(scheduled.map { FlightFormat.localTime($0, timeZone: zone) } ?? "")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(best.map { FlightFormat.localTime($0, timeZone: zone) } ?? "--")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if best != nil {
                    Text(actual ? "actual" : "est.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GatesCard: View {
    var flight: TrackedFlight

    var body: some View {
        let d = flight.snapshot.departure, a = flight.snapshot.arrival
        Card(title: "Gates") {
            HStack(alignment: .top) {
                GateBlock(title: "Departure", airport: d.airport, terminal: d.terminal, gate: d.gate, extra: d.checkInDesk.map { "Check-in \($0)" })
                Spacer()
                GateBlock(title: "Arrival", airport: a.airport, terminal: a.terminal, gate: a.gate, extra: a.baggageBelt.map { "Baggage belt \($0)" })
            }
            if let runway = d.runway { Text("Departure runway \(runway)").font(.caption).foregroundStyle(.secondary) }
            if let runway = a.runway { Text("Arrival runway \(runway)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct GateBlock: View {
    var title: String
    var airport: AirportRef
    var terminal: String?
    var gate: String?
    var extra: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(airport.code)").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Terminal").font(.caption2).foregroundStyle(.secondary)
                    Text(terminal ?? "-").font(.title3.weight(.bold))
                }
                VStack(alignment: .leading) {
                    Text("Gate").font(.caption2).foregroundStyle(.secondary)
                    Text(gate ?? "TBD").font(.title3.weight(.bold))
                }
            }
            if let extra { Text(extra).font(.subheadline.weight(.semibold)).foregroundStyle(.yellow) }
        }
    }
}

private struct ProfileCharts: View {
    var track: [TrackPoint]

    /// Ground speed between consecutive fixes (knots), since OpenSky tracks carry no speed.
    private var speeds: [(Date, Double)] {
        zip(track, track.dropFirst()).compactMap { a, b in
            let dt = b.time.timeIntervalSince(a.time)
            guard dt > 20 else { return nil }
            let nm = Geo.distanceNm(Coordinate(latitude: a.latitude, longitude: a.longitude), Coordinate(latitude: b.latitude, longitude: b.longitude))
            return (b.time, nm / dt * 3600)
        }
    }

    var body: some View {
        Card(title: "Altitude and speed") {
            Chart(track, id: \.time) { p in
                AreaMark(x: .value("Time", p.time), y: .value("Altitude (ft)", p.altitudeFt ?? 0))
                    .foregroundStyle(.cyan.opacity(0.35))
                LineMark(x: .value("Time", p.time), y: .value("Altitude (ft)", p.altitudeFt ?? 0))
                    .foregroundStyle(.cyan)
            }
            .chartYAxisLabel("ft")
            .frame(height: 120)
            if speeds.count >= 2 {
                Chart(speeds, id: \.0) { item in
                    LineMark(x: .value("Time", item.0), y: .value("Ground speed (kt)", item.1))
                        .foregroundStyle(.orange)
                }
                .chartYAxisLabel("kt")
                .frame(height: 100)
            }
        }
    }
}

private struct InboundCard: View {
    var inbound: FlightSnapshot
    var ours: FlightSnapshot

    var body: some View {
        let late = InboundAircraftCheck.minutesLate(inbound: inbound, ours: ours)
        Card(title: "Where's my plane") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(inbound.number)  \(inbound.departure.airport.code) → \(inbound.arrival.airport.code)").font(.headline)
                    Text(inbound.status == .arrived
                         ? "Arrived \(FlightFormat.localTime(inbound.arrival.times.bestGate, timeZone: inbound.arrival.airport.timeZone))"
                         : "Lands \(FlightFormat.localTime(inbound.arrival.times.bestGate, timeZone: inbound.arrival.airport.timeZone))")
                        .font(.subheadline)
                }
                Spacer()
                if late > 0 {
                    StatusPill(text: "Could delay you \(FlightFormat.duration(TimeInterval(late * 60)))", tone: late >= 30 ? .majorDelay : .minorDelay)
                } else {
                    StatusPill(text: inbound.status == .arrived ? "Here" : "On track", tone: .onTime)
                }
            }
        }
    }
}

private struct AircraftCard: View {
    var flight: TrackedFlight

    var body: some View {
        let s = flight.snapshot
        Card(title: "Aircraft") {
            LabeledContent("Type", value: s.aircraft?.model ?? "Not assigned yet")
            LabeledContent("Tail number", value: s.aircraft?.registration ?? "-")
            LabeledContent("Mode-S", value: s.aircraft?.modeS?.uppercased() ?? "-")
            if let nm = s.greatCircleNm {
                LabeledContent("Distance", value: "\(Int(nm)) nm · \(Int(Units.nmToStatuteMiles(nm))) mi")
            }
            if let p = flight.position, flight.phase.isInAir {
                LabeledContent("Altitude", value: p.altitudeFt.map { "\($0.formatted()) ft" } ?? "-")
                LabeledContent("Ground speed", value: p.groundSpeedKt.map { "\($0) kt" } ?? "-")
                LabeledContent("Position from", value: p.source.label)
            }
        }
        .font(.subheadline)
    }
}

private extension PositionSource {
    var label: String {
        switch self {
        case .aeroDataBox: return "AeroDataBox"
        case .openSky: return "OpenSky ADS-B"
        case .device: return "Your phone's GPS"
        case .deadReckoned: return "Estimated (no signal)"
        }
    }
}

private struct LiveControls: View {
    @Environment(AppModel.self) private var model
    var flight: TrackedFlight

    var body: some View {
        let live = model.isLive(flight.id)
        let isDemo = model.demoFlight?.id == flight.id
        VStack(spacing: 8) {
            if isDemo {
                Button(role: .destructive) { Task { await model.stopDemo() } } label: {
                    Label("Stop simulation", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if live {
                Button(role: .destructive) { Task { await model.stopLiveTracking(flight.id) } } label: {
                    Label("Stop live tracking", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if !flight.phase.isTerminal {
                Button { Task { await model.startLiveTracking(flight.id) } } label: {
                    Label("Start live tracking", systemImage: "lock.iphone").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text(model.isInActiveWindow(flight)
                     ? "Puts this flight on your Lock Screen and keeps checking in the background."
                     : "Starts automatically 3 hours before departure when you open the app, or from the reminder notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct FreshnessFooter: View {
    var flight: TrackedFlight

    var body: some View {
        VStack(spacing: 4) {
            if let last = flight.lastStatusPoll {
                Text("Status checked \(last.formatted(.relative(presentation: .named)))")
            }
            if let error = flight.lastError {
                Text(error).foregroundStyle(.orange)
            }
            Text("Data: AeroDataBox (schedule, gates) and OpenSky (position)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}
