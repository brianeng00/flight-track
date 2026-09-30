import FlightCore
import SwiftUI

struct FlightListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !model.isConfigured {
                    SetupBanner()
                }
                if let expiry = AppConfig.profileExpiry, expiry.timeIntervalSinceNow < 2 * 24 * 3600 {
                    Label("This install expires \(expiry.formatted(.relative(presentation: .named))). Reinstall from Xcode before your trip.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                if let demo = model.demoFlight {
                    Section("Simulation") {
                        NavigationLink(value: demo.id) { FlightCard(flight: demo, isLive: true) }
                    }
                }
                Section {
                    if model.activeFlights.isEmpty {
                        ContentUnavailableView("No upcoming flights", systemImage: "airplane.departure",
                                               description: Text("Tap + and enter a flight number and date."))
                    }
                    ForEach(model.activeFlights) { flight in
                        NavigationLink(value: flight.id) { FlightCard(flight: flight, isLive: model.isLive(flight.id)) }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { model.activeFlights[$0].id }
                        Task { for id in ids { await model.remove(id) } }
                    }
                } header: {
                    Text("Upcoming")
                } footer: {
                    Text("AeroDataBox budget: \(model.budget.remaining) of \(model.budget.monthlyUnits) units left, about \(model.flightsLeftThisMonth) flights.")
                }
                if !model.pastFlights.isEmpty {
                    Section("Past") {
                        ForEach(model.pastFlights) { flight in
                            NavigationLink(value: flight.id) { FlightCard(flight: flight, isLive: false) }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { model.pastFlights[$0].id }
                            Task { for id in ids { await model.remove(id) } }
                        }
                    }
                }
            }
            .navigationTitle("Flights")
            .navigationDestination(for: UUID.self) { id in FlightDetailView(flightID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .disabled(!model.isConfigured)
                }
            }
            .refreshable { await model.tick(force: true) }
            .sheet(isPresented: $showingAdd) { AddFlightView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.lastError ?? "")
            }
            .onChange(of: model.selectedFlightID) { _, id in
                // Deep link / notification tap: jump to that flight.
                if let id { path = [id]; model.selectedFlightID = nil }
            }
        }
    }
}

private struct SetupBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Add your AeroDataBox key", systemImage: "key.fill").font(.headline)
            Text("Copy ios/Config/Secrets.example.xcconfig to Secrets.xcconfig, paste your free AeroDataBox key, and run again from Xcode. Until then, try Settings > Simulate a flight.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct FlightCard: View {
    var flight: TrackedFlight
    var isLive: Bool

    var body: some View {
        let s = flight.snapshot
        let delay = FlightFormat.relevantDelay(flight)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.number).font(.headline)
                if isLive {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green).font(.caption)
                }
                Spacer()
                StatusPill(text: FlightFormat.statusText(delayMinutes: delay, phase: flight.phase),
                           tone: FlightFormat.tone(delayMinutes: delay, phase: flight.phase))
            }
            HStack(alignment: .firstTextBaseline) {
                EndpointColumn(code: s.departure.airport.code, time: s.departure.times.bestGate,
                               scheduled: s.departure.times.scheduled, zone: s.departure.airport.timeZone, alignment: .leading)
                Spacer()
                Image(systemName: "airplane").foregroundStyle(.secondary)
                Spacer()
                EndpointColumn(code: s.arrival.airport.code, time: s.arrival.times.bestGate,
                               scheduled: s.arrival.times.scheduled, zone: s.arrival.airport.timeZone, alignment: .trailing)
            }
            HStack {
                Text(FlightFormat.gateLine(s.departure))
                Spacer()
                if let date = s.departure.times.scheduled {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct EndpointColumn: View {
    var code: String
    var time: Date?
    var scheduled: Date?
    var zone: TimeZone
    var alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(code).font(.title2.weight(.bold)).monospaced()
            Text(FlightFormat.localTime(time, timeZone: zone)).font(.subheadline.weight(.semibold))
            if let scheduled, let time, abs(time.timeIntervalSince(scheduled)) >= 5 * 60 {
                Text(FlightFormat.localTime(scheduled, timeZone: zone))
                    .font(.caption)
                    .strikethrough()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
