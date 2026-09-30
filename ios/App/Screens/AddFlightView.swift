import FlightCore
import SwiftUI

/// Type a flight number and date, pick the leg, track it.
struct AddFlightView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var date = Date()
    @State private var results: [FlightSnapshot] = []
    @State private var searching = false
    @State private var message: String?
    @FocusState private var numberFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Flight number, e.g. UA 1234", text: $number)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($numberFocused)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    DatePicker("Departure date", selection: $date, displayedComponents: .date)
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Text("Find flight")
                            if searching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(FlightNumber.normalize(number).count < 3 || searching)
                } footer: {
                    Text("Each search uses 2 of your \(model.budget.remaining) remaining AeroDataBox units.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }

                if !results.isEmpty {
                    Section(results.count == 1 ? "Found" : "Pick your leg") {
                        ForEach(results, id: \.legKey) { leg in
                            Button {
                                Task {
                                    await model.add(leg, searchedNumber: number, date: date)
                                    dismiss()
                                }
                            } label: {
                                LegRow(leg: leg)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { numberFocused = true }
        }
    }

    private func search() async {
        guard !searching else { return }
        searching = true
        message = nil
        defer { searching = false }
        do {
            results = try await model.search(number: number, date: date).filter { !$0.isCargo }
            if results.isEmpty { message = "No flights found for \(FlightNumber.display(number)) on that date." }
        } catch {
            results = []
            message = String(describing: error)
        }
    }
}

private struct LegRow: View {
    var leg: FlightSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(leg.departure.airport.code) → \(leg.arrival.airport.code)").font(.headline)
                Spacer()
                Text(leg.status.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(leg.departure.airport.city ?? leg.departure.airport.name) to \(leg.arrival.airport.city ?? leg.arrival.airport.name)")
                .font(.subheadline)
            Text("Departs \(FlightFormat.localTime(leg.departure.times.scheduled, timeZone: leg.departure.airport.timeZone)) · arrives \(FlightFormat.localTime(leg.arrival.times.scheduled, timeZone: leg.arrival.airport.timeZone))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
