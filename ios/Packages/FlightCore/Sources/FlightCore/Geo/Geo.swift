import Foundation

/// Unit conversions ported from `src/lib/geo.ts`. Rounding matches JS `Math.round`
/// (half rounds toward +infinity) so both apps show identical numbers.
public enum Units {
    public static func metersToFeet(_ m: Double) -> Int { jsRound(m * 3.28084) }
    public static func msToKnots(_ ms: Double) -> Int { jsRound(ms * 1.94384) }
    public static func msToFeetPerMinute(_ ms: Double) -> Int { jsRound(ms * 196.850394) }
    public static func nmToStatuteMiles(_ nm: Double) -> Double { nm * 1.150779 }

    static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }
}

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    static let earthRadiusNm = 3440.065
    static let earthRadiusM = 6_371_000.0
    static let degToRad = Double.pi / 180
    static let radToDeg = 180 / Double.pi

    /// Haversine distance in nautical miles. Port of `haversineDistance` in `src/lib/geo.ts`.
    public static func distanceNm(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = (b.latitude - a.latitude) * degToRad
        let dLng = (b.longitude - a.longitude) * degToRad
        let h = pow(sin(dLat / 2), 2)
            + cos(a.latitude * degToRad) * cos(b.latitude * degToRad) * pow(sin(dLng / 2), 2)
        return earthRadiusNm * 2 * asin(sqrt(h))
    }

    /// Projects a position forward along a heading. Port of `deadReckon` in `src/lib/deadReckon.ts`,
    /// same limitations: straight line, no turns; on-ground or zero speed returns the input.
    public static func deadReckon(
        from start: Coordinate, speedMs: Double, headingDeg: Double, elapsed: TimeInterval, onGround: Bool
    ) -> Coordinate {
        if onGround || speedMs <= 0 || elapsed <= 0 { return start }
        let angular = speedMs * elapsed / earthRadiusM
        let heading = headingDeg * degToRad
        let lat1 = start.latitude * degToRad
        let lng1 = start.longitude * degToRad
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(heading))
        let lng2 = lng1 + atan2(sin(heading) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        let lngDeg = lng2 * radToDeg
        // Same normalisation as the TS version: ((x + 540) % 360) - 180, with JS remainder semantics.
        return Coordinate(latitude: lat2 * radToDeg, longitude: fmod(lngDeg + 540, 360) - 180)
    }

    /// Initial great-circle bearing from `a` to `b`, degrees clockwise from north (0 to 360).
    public static func bearingDeg(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * degToRad, lat2 = b.latitude * degToRad
        let dLng = (b.longitude - a.longitude) * degToRad
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        return fmod(atan2(y, x) * radToDeg + 360, 360)
    }

    /// `count` points evenly spaced along the great circle from `a` to `b` (inclusive of both ends).
    public static func greatCircle(_ a: Coordinate, _ b: Coordinate, count: Int) -> [Coordinate] {
        guard count >= 2 else { return [a, b] }
        let lat1 = a.latitude * degToRad, lng1 = a.longitude * degToRad
        let lat2 = b.latitude * degToRad, lng2 = b.longitude * degToRad
        let d = distanceNm(a, b) / earthRadiusNm
        if d < 1e-9 { return Array(repeating: a, count: count) }
        return (0..<count).map { i in
            let f = Double(i) / Double(count - 1)
            let A = sin((1 - f) * d) / sin(d)
            let B = sin(f * d) / sin(d)
            let x = A * cos(lat1) * cos(lng1) + B * cos(lat2) * cos(lng2)
            let y = A * cos(lat1) * sin(lng1) + B * cos(lat2) * sin(lng2)
            let z = A * sin(lat1) + B * sin(lat2)
            return Coordinate(latitude: atan2(z, sqrt(x * x + y * y)) * radToDeg, longitude: atan2(y, x) * radToDeg)
        }
    }

    /// Fraction of the trip done (0 to 1), from where the plane is relative to both airports.
    /// Uses flown / (flown + remaining) so a detour doesn't push progress past 1.
    public static func progress(from origin: Coordinate, to destination: Coordinate, at position: Coordinate) -> Double {
        let flown = distanceNm(origin, position)
        let remaining = distanceNm(position, destination)
        let total = flown + remaining
        guard total > 0 else { return 0 }
        return min(max(flown / total, 0), 1)
    }

    /// Time-based progress between takeoff and ETA; the fallback when there is no position.
    public static func progress(takeoff: Date, eta: Date, now: Date) -> Double {
        let span = eta.timeIntervalSince(takeoff)
        guard span > 0 else { return now >= eta ? 1 : 0 }
        return min(max(now.timeIntervalSince(takeoff) / span, 0), 1)
    }
}
