import ActivityKit
import FlightCore
import Foundation

/// The ActivityKit type shared by the app (starts/updates) and the widget (draws).
/// Both halves are FlightCore models, so the rules that build them are unit-tested on Linux.
struct FlightActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityState
    var info: LiveActivityStatic
}

enum AppGroup {
    /// From Info.plist `FTAppGroup`, which Base.xcconfig derives from your bundle ID.
    static var identifier: String {
        (Bundle.main.object(forInfoDictionaryKey: "FTAppGroup") as? String) ?? "group.com.example.flighttrack"
    }

    /// Shared container, or the app's own Documents if the App Group isn't provisioned
    /// (then the widget just falls back to the drawn route instead of the map image).
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func mapImageURL(named file: String) -> URL {
        containerURL.appendingPathComponent(file)
    }
}

/// Deep links from the Live Activity and notifications: flighttrack://flight/<uuid>
enum DeepLink {
    static func flight(_ id: UUID) -> URL { URL(string: "flighttrack://flight/\(id.uuidString)")! }

    static func flightID(from url: URL) -> UUID? {
        guard url.scheme == "flighttrack", url.host == "flight" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
