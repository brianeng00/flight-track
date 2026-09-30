import FlightCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("AeroDataBox", value: model.isConfigured ? "Key set" : "Missing key")
                    LabeledContent("OpenSky", value: AppConfig.openSkyCredentials == nil ? "Anonymous (lower limit)" : "Signed in")
                    LabeledContent("Units left this month", value: "\(model.budget.remaining) / \(model.budget.monthlyUnits)")
                    LabeledContent("About", value: "\(model.flightsLeftThisMonth) flights")
                } header: {
                    Text("Data")
                } footer: {
                    Text("Free AeroDataBox plan: 600 units a month, 2 per status check. The app keeps \(model.budget.reserveUnits) units in reserve so a flight in progress never goes dark.")
                }

                Section {
                    Toggle("Keep tracking while locked", isOn: binding(\.keepAliveEnabled))
                    Toggle("Map on Live Activity", isOn: binding(\.mapOnLiveActivity))
                    Toggle("Remind me to reinstall", isOn: binding(\.remindBeforeProfileExpiry))
                    if let expiry = AppConfig.profileExpiry {
                        LabeledContent("This install expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                    if !model.liveActivitiesEnabled {
                        Label("Live Activities are off: Settings > FlightTrack", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Free account mode")
                } footer: {
                    Text("Without paid push notifications, the app stays running with location on (blue pill in the status bar) during a flight's active window, from 3 hours before departure until your bags arrive. That's what keeps the Lock Screen and alerts live.")
                }

                Section {
                    if model.demoFlight == nil {
                        Button("Fast (about 4 minutes)") { start(speed: 120) }
                        Button("Medium (about 15 minutes)") { start(speed: 30) }
                        Button("Real time (keep-alive endurance test, about 6 hours)") { start(speed: 1) }
                    } else {
                        Button("Stop simulation", role: .destructive) { Task { await model.stopDemo() } }
                    }
                } header: {
                    Text("Simulate a flight")
                } footer: {
                    Text("Plays FT 101 AUS → ORD through the real engine, Live Activity and notifications: gate change, 25 minute delay, late inbound plane, boarding, takeoff, landing, bags. Lock your phone to watch it.")
                }

                HeartbeatSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func start(speed: Double) {
        Task {
            await model.startDemo(speed: speed)
            dismiss()
        }
    }

    private func binding(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in model.updateSettings { $0[keyPath: key] = value } })
    }
}

/// Evidence for the keep-alive spike: did the loop keep running while the phone was locked?
private struct HeartbeatSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.heartbeat.summary(lastHours: 6)
        Section {
            LabeledContent("Loop runs (last 6 h)", value: "\(s.beats)")
            LabeledContent("While in background", value: "\(s.backgroundBeats)")
            LabeledContent("Longest gap", value: s.beats < 2 ? "-" : FlightFormat.duration(s.longestGap))
            if let ended = s.longestGapEndedAt, s.longestGap > 120 {
                LabeledContent("Gap ended", value: ended.formatted(date: .omitted, time: .shortened))
            }
            Button("Clear log", role: .destructive) { model.clearHeartbeat() }
        } header: {
            Text("Keep-alive check")
        } footer: {
            Text("The loop runs every 30 seconds while tracking. Gaps longer than a couple of minutes while locked mean iOS suspended the app, so the free-account approach isn't reliable on your phone.")
        }
    }
}
