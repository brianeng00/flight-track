import XCTest
@testable import FlightCore

/// Swift ports must agree with the web app's TypeScript. The table in geo_parity.json was produced
/// by running `src/lib/geo.ts` and `src/lib/deadReckon.ts` under Node.
final class GeoParityTests: XCTestCase {
    struct Table: Decodable {
        struct Hav: Decodable { var a: [Double]; var b: [Double]; var nm: Double }
        struct DR: Decodable {
            var lat: Double; var lng: Double; var speedMs: Double; var headingDeg: Double
            var deltaMs: Double; var onGround: Bool; var out: [Double]
        }
        struct U: Decodable { var v: Double; var feet: Int; var knots: Int }
        var haversine: [Hav]
        var deadReckon: [DR]
        var units: [U]
    }

    func testMatchesTypeScript() throws {
        let table = try JSONDecoder().decode(Table.self, from: try Fixture.data("geo_parity"))
        for h in table.haversine {
            let nm = Geo.distanceNm(Coordinate(latitude: h.a[0], longitude: h.a[1]), Coordinate(latitude: h.b[0], longitude: h.b[1]))
            XCTAssertEqual(nm, h.nm, accuracy: 1e-6)
        }
        for d in table.deadReckon {
            let out = Geo.deadReckon(from: Coordinate(latitude: d.lat, longitude: d.lng), speedMs: d.speedMs,
                                     headingDeg: d.headingDeg, elapsed: d.deltaMs / 1000, onGround: d.onGround)
            XCTAssertEqual(out.latitude, d.out[0], accuracy: 1e-9)
            XCTAssertEqual(out.longitude, d.out[1], accuracy: 1e-9)
        }
        for u in table.units {
            XCTAssertEqual(Units.metersToFeet(u.v), u.feet, "feet for \(u.v)")
            XCTAssertEqual(Units.msToKnots(u.v), u.knots, "knots for \(u.v)")
        }
        XCTAssertGreaterThan(table.haversine.count, 10)
    }

    func testGreatCircleEndsAtAirports() {
        let aus = Coordinate(latitude: 30.1945, longitude: -97.6699)
        let ord = Coordinate(latitude: 41.9786, longitude: -87.9048)
        let path = Geo.greatCircle(aus, ord, count: 16)
        XCTAssertEqual(path.count, 16)
        XCTAssertEqual(path.first!.latitude, aus.latitude, accuracy: 1e-9)
        XCTAssertEqual(path.last!.longitude, ord.longitude, accuracy: 1e-9)
        // Midpoint splits the distance in half.
        let mid = Geo.greatCircle(aus, ord, count: 3)[1]
        XCTAssertEqual(Geo.distanceNm(aus, mid), Geo.distanceNm(mid, ord), accuracy: 1e-6)
    }

    func testProgress() {
        let aus = Coordinate(latitude: 30.1945, longitude: -97.6699)
        let ord = Coordinate(latitude: 41.9786, longitude: -87.9048)
        let mid = Geo.greatCircle(aus, ord, count: 3)[1]
        XCTAssertEqual(Geo.progress(from: aus, to: ord, at: mid), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Geo.progress(from: aus, to: ord, at: aus), 0, accuracy: 1e-9)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Geo.progress(takeoff: t0, eta: t0.addingTimeInterval(100), now: t0.addingTimeInterval(25)), 0.25)
        XCTAssertEqual(Geo.progress(takeoff: t0, eta: t0.addingTimeInterval(100), now: t0.addingTimeInterval(500)), 1)
    }

    func testBearing() {
        XCTAssertEqual(Geo.bearingDeg(Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 1, longitude: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(Geo.bearingDeg(Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 1)), 90, accuracy: 1e-9)
    }
}

final class ModelTests: XCTestCase {
    func testFlightNumberNormalization() {
        XCTAssertEqual(FlightNumber.normalize("ua 123"), "UA123")
        XCTAssertEqual(FlightNumber.normalize(" UA0123 "), "UA123")
        XCTAssertEqual(FlightNumber.normalize("B6 0415"), "B6415")
        XCTAssertEqual(FlightNumber.normalize("9E5001"), "9E5001")
        XCTAssertEqual(FlightNumber.normalize("UAL123"), "UAL123")
        XCTAssertEqual(FlightNumber.display("dl47"), "DL 47")
        XCTAssertEqual(FlightNumber.display("UAL0123"), "UAL 123")
        XCTAssertEqual(FlightNumber.display("B6415"), "B6 415")
    }

    func testPickLegByAirportAndTime() throws {
        let legs = try AeroDataBoxDecoder.decodeFlights(try Fixture.data("adb_ua1234_full"), fetchedAt: Date())
        XCTAssertNil(FlightQuery(number: "UA1234", date: "2026-10-05").pickLeg(from: legs), "two legs: must ask the person")
        let ord = FlightQuery(number: "UA1234", date: "2026-10-05", departureAirportCode: "KORD")
        XCTAssertEqual(ord.pickLeg(from: legs)?.arrival.airport.code, "BOS")
        let aus = FlightQuery(number: "UA1234", date: "2026-10-05", departureAirportCode: "aus",
                              scheduledDeparture: utc("2026-10-05T14:30:00Z"))
        XCTAssertEqual(aus.pickLeg(from: legs)?.arrival.airport.code, "ORD")
    }

    func testLegKeyStableAcrossPolls() {
        let dep = utc("2026-10-05T14:30:00Z")
        let a = makeSnapshot(departure: dep)
        let b = makeSnapshot(departure: dep, status: .delayed, depRevised: dep.addingTimeInterval(1800))
        XCTAssertEqual(a.legKey, b.legKey)
        XCTAssertEqual(a.legKey, "UA1234|AUS|2026-10-05")
    }

    func testDelayMinutes() {
        let dep = utc("2026-10-05T14:30:00Z")
        XCTAssertEqual(makeSnapshot(departure: dep).departure.delayMinutes, 0)
        XCTAssertEqual(makeSnapshot(departure: dep, depRevised: dep.addingTimeInterval(25 * 60)).departure.delayMinutes, 25)
        XCTAssertEqual(makeSnapshot(departure: dep, depRevised: dep.addingTimeInterval(-6 * 60)).departure.delayMinutes, -6)
    }
}

final class FormattingTests: XCTestCase {
    func testStatusTextAndTone() {
        XCTAssertEqual(FlightFormat.statusText(delayMinutes: 0, phase: .scheduled), "On time")
        XCTAssertEqual(FlightFormat.statusText(delayMinutes: 25, phase: .scheduled), "Delayed 25m")
        XCTAssertEqual(FlightFormat.statusText(delayMinutes: 75, phase: .boarding), "Delayed 1h 15m")
        XCTAssertEqual(FlightFormat.statusText(delayMinutes: -12, phase: .airborne), "12m early")
        XCTAssertEqual(FlightFormat.statusText(delayMinutes: 90, phase: .canceled), "Canceled")
        XCTAssertEqual(FlightFormat.tone(delayMinutes: 14, phase: .scheduled), .onTime)
        XCTAssertEqual(FlightFormat.tone(delayMinutes: 15, phase: .scheduled), .minorDelay)
        XCTAssertEqual(FlightFormat.tone(delayMinutes: 45, phase: .scheduled), .majorDelay)
        XCTAssertEqual(FlightFormat.tone(delayMinutes: 0, phase: .canceled), .canceled)
    }

    func testLocalTimeUsesAirportZone() {
        XCTAssertEqual(FlightFormat.localTime(utc("2026-10-05T14:30:00Z"), timeZone: chicago), "9:30 AM")
        XCTAssertEqual(FlightFormat.localTime(utc("2026-10-05T14:30:00Z"), timeZone: TimeZone(identifier: "America/New_York")!), "10:30 AM")
        XCTAssertEqual(FlightFormat.localTime(nil, timeZone: chicago), "--:--")
    }

    func testDuration() {
        XCTAssertEqual(FlightFormat.duration(0), "0m")
        XCTAssertEqual(FlightFormat.duration(45 * 60), "45m")
        XCTAssertEqual(FlightFormat.duration(72 * 60), "1h 12m")
        XCTAssertEqual(FlightFormat.duration(-60), "0m")
    }
}
