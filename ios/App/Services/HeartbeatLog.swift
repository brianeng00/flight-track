import Foundation
import UIKit

/// Records when the tracking loop actually ran, so the keep-alive spike (M1a) has evidence:
/// if iOS suspends the app while locked, the log shows the gap.
struct HeartbeatLog: Codable, Equatable {
    struct Beat: Codable, Equatable {
        var at: Date
        var inBackground: Bool
    }

    private(set) var beats: [Beat] = []
    /// Keep about a day at one beat per 30 s.
    static let maxBeats = 3000

    mutating func record(at date: Date, inBackground: Bool) {
        beats.append(Beat(at: date, inBackground: inBackground))
        if beats.count > Self.maxBeats { beats.removeFirst(beats.count - Self.maxBeats) }
    }

    mutating func clear() { beats.removeAll() }

    struct Summary: Equatable {
        var windowHours: Double
        var beats: Int
        var backgroundBeats: Int
        var longestGap: TimeInterval
        var longestGapEndedAt: Date?
    }

    /// Stats over the last `hours`.
    func summary(lastHours hours: Double, now: Date = Date()) -> Summary {
        let since = now.addingTimeInterval(-hours * 3600)
        let recent = beats.filter { $0.at >= since }
        var longest: TimeInterval = 0
        var endedAt: Date?
        for (a, b) in zip(recent, recent.dropFirst()) where b.at.timeIntervalSince(a.at) > longest {
            longest = b.at.timeIntervalSince(a.at)
            endedAt = b.at
        }
        return Summary(windowHours: hours, beats: recent.count, backgroundBeats: recent.filter(\.inBackground).count,
                       longestGap: longest, longestGapEndedAt: endedAt)
    }
}

final class HeartbeatStore {
    private let url = AppGroup.containerURL.appendingPathComponent("flighttrack-heartbeat.json")

    func load() -> HeartbeatLog {
        guard let data = try? Data(contentsOf: url), let log = try? JSONDecoder().decode(HeartbeatLog.self, from: data) else {
            return HeartbeatLog()
        }
        return log
    }

    func save(_ log: HeartbeatLog) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
