import Foundation

/// A flight the person is following, plus everything the engine remembers about it.
/// Persisted as JSON in the App Group so the app and widget see the same thing.
public struct TrackedFlight: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var query: FlightQuery
    public var snapshot: FlightSnapshot
    public var phase: FlightPhase
    /// Latest live position from any source (OpenSky, device GPS, dead reckoning).
    public var position: LivePosition?
    public var track: [TrackPoint]
    /// The aircraft's previous leg, when we found it ("Where's my plane").
    public var inbound: FlightSnapshot?
    /// Dedupe keys of events already delivered, so a repeated poll never re-alerts.
    public var deliveredEventKeys: Set<String>
    public var lastStatusPoll: Date?
    public var lastPositionPoll: Date?
    public var lastInboundPoll: Date?
    public var lastError: String?
    public var addedAt: Date
    public var liveActivityID: String?
    public var isArchived: Bool

    public init(
        id: UUID = UUID(), query: FlightQuery, snapshot: FlightSnapshot, now: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.snapshot = snapshot
        self.phase = PhaseResolver.resolve(snapshot, position: nil, now: now)
        self.position = snapshot.position
        self.track = []
        self.inbound = nil
        self.deliveredEventKeys = []
        self.lastStatusPoll = snapshot.fetchedAt
        self.lastPositionPoll = nil
        self.lastInboundPoll = nil
        self.lastError = nil
        self.addedAt = now
        self.liveActivityID = nil
        self.isArchived = false
    }

    public var departureCoordinate: Coordinate? { snapshot.departure.airport.coordinate }
    public var arrivalCoordinate: Coordinate? { snapshot.arrival.airport.coordinate }

    /// 0 to 1. Position-based when we have a fresh fix, time-based otherwise.
    public func progress(now: Date) -> Double {
        switch phase {
        case .scheduled, .boarding, .departed, .canceled: return 0
        case .landed, .arrived: return 1
        case .airborne, .diverted: break
        }
        if let pos = position, now.timeIntervalSince(pos.reportedAt) < 15 * 60,
           let dep = departureCoordinate, let arr = arrivalCoordinate {
            return Geo.progress(from: dep, to: arr, at: Coordinate(latitude: pos.latitude, longitude: pos.longitude))
        }
        if let takeoff = snapshot.departure.times.runway ?? snapshot.departure.times.revised,
           let eta = snapshot.arrival.times.runway ?? snapshot.arrival.times.bestGate {
            return Geo.progress(takeoff: takeoff, eta: eta, now: now)
        }
        return 0.5
    }
}

extension AirportRef {
    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}
