import FlightCore
import Foundation

/// JSON persistence in the App Group container. Small data (a handful of flights), so a
/// whole-file rewrite on every change is simpler and safer than a database.
struct AppSettings: Codable, Equatable {
    /// Keep the app alive in the background with location while a flight is live-tracked.
    var keepAliveEnabled = true
    /// Draw the route over a pre-rendered map on the Live Activity (off = plain drawn arc).
    var mapOnLiveActivity = true
    /// Remind me to reinstall before the free-account profile expires.
    var remindBeforeProfileExpiry = true
}

struct StoredState: Codable {
    var flights: [TrackedFlight] = []
    var budget: UnitBudget
    var settings = AppSettings()
}

final class FlightStore {
    private let url = AppGroup.containerURL.appendingPathComponent("flighttrack-state.json")
    private let queue = DispatchQueue(label: "FlightStore")

    func load() -> StoredState {
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(StoredState.self, from: data) else {
            return StoredState(budget: UnitBudget(periodStart: Self.startOfMonth()))
        }
        return state
    }

    func save(_ state: StoredState) {
        let url = self.url
        queue.async {
            guard let data = try? Self.encoder.encode(state) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func startOfMonth() -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
    }
}
