import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FlightCore

final class TimestampParserTests: XCTestCase {
    func testAeroDataBoxAndISOShapes() {
        let expected = Date(timeIntervalSince1970: 1_791_210_600) // 2026-10-05 14:30:00 UTC
        XCTAssertEqual(TimestampParser.parse("2026-10-05 14:30Z"), expected)
        XCTAssertEqual(TimestampParser.parse("2026-10-05 09:30-05:00"), expected)
        XCTAssertEqual(TimestampParser.parse("2026-10-05T14:30:00Z"), expected)
        XCTAssertEqual(TimestampParser.parse("2026-10-05T14:30:00.000Z"), expected)
        XCTAssertEqual(TimestampParser.parse("2026-10-05T14:30"), expected)
    }

    func testGarbageIsNil() {
        XCTAssertNil(TimestampParser.parse(nil))
        XCTAssertNil(TimestampParser.parse(""))
        XCTAssertNil(TimestampParser.parse("tomorrow-ish"))
    }
}

final class AeroDataBoxTests: XCTestCase {
    func testDecodesFullFlightContract() throws {
        let legs = try AeroDataBoxDecoder.decodeFlights(try Fixture.data("adb_ua1234_full"), fetchedAt: Date())
        XCTAssertEqual(legs.count, 2)
        let leg = legs[0]
        XCTAssertEqual(leg.number, "UA 1234")
        XCTAssertEqual(leg.status, .enRoute)
        XCTAssertEqual(leg.airlineIATA, "UA")
        XCTAssertEqual(leg.departure.airport.code, "AUS")
        XCTAssertEqual(leg.departure.airport.name, "Austin-Bergstrom")
        XCTAssertEqual(leg.departure.airport.timeZoneID, "America/Chicago")
        XCTAssertEqual(leg.departure.gate, "B18")
        XCTAssertEqual(leg.departure.terminal, "1")
        XCTAssertEqual(leg.departure.times.scheduled, utc("2026-10-05T14:30:00Z"))
        XCTAssertEqual(leg.departure.times.revised, utc("2026-10-05T14:52:00Z"))
        XCTAssertEqual(leg.departure.times.runway, utc("2026-10-05T15:04:00Z"))
        XCTAssertEqual(leg.departure.delayMinutes, 22)
        XCTAssertTrue(leg.departure.isLive)
        XCTAssertEqual(leg.arrival.times.predicted, utc("2026-10-05T17:18:00Z"))
        XCTAssertNil(leg.arrival.baggageBelt, "empty string should read as missing")
        XCTAssertEqual(leg.aircraft?.modeS, "a4b3c2", "Mode-S is lowercased to match OpenSky icao24")
        XCTAssertEqual(leg.aircraft?.registration, "N37502")
        XCTAssertEqual(leg.greatCircleNm, 850.2)
        let pos = try XCTUnwrap(leg.position)
        XCTAssertEqual(pos.altitudeFt, 36000)
        XCTAssertEqual(pos.groundSpeedKt, 471)
        XCTAssertTrue(pos.isAirborne)
        XCTAssertEqual(pos.source, .aeroDataBox)

        XCTAssertEqual(legs[1].arrival.airport.code, "BOS")
        XCTAssertNil(legs[1].aircraft)
        XCTAssertFalse(legs[1].departure.isLive)
    }

    func testToleratesUnknownStatusAndMissingFields() throws {
        let legs = try AeroDataBoxDecoder.decodeFlights(try Fixture.data("adb_unknown_fields"), fetchedAt: Date())
        XCTAssertEqual(legs.first?.status, .unknown)
        XCTAssertEqual(legs.first?.departure.airport.code, "???")
        XCTAssertEqual(legs.first?.number, "9E 5001")
    }

    func testRequestShapeForBothMarketplaces() {
        let market = AeroDataBoxClient(marketplace: .apiMarket(key: "k1")).makeRequest(searchBy: "number", param: "UA1234", date: "2026-10-05")
        XCTAssertEqual(market.url?.host, "prod.api.market")
        XCTAssertTrue(market.url!.path.hasSuffix("/aedbx/aerodatabox/flights/number/UA1234/2026-10-05"))
        XCTAssertEqual(market.value(forHTTPHeaderField: "x-api-market-key"), "k1")
        XCTAssertTrue(market.url!.query!.contains("withLocation=false"))
        XCTAssertTrue(market.url!.query!.contains("dateLocalRole=Both"))

        let rapid = AeroDataBoxClient(marketplace: .rapidAPI(key: "k2")).makeRequest(searchBy: "reg", param: "N37502", date: "2026-10-05")
        XCTAssertEqual(rapid.url?.host, "aerodatabox.p.rapidapi.com")
        XCTAssertEqual(rapid.url?.path, "/flights/reg/N37502/2026-10-05")
        XCTAssertEqual(rapid.value(forHTTPHeaderField: "X-RapidAPI-Key"), "k2")
        XCTAssertEqual(rapid.value(forHTTPHeaderField: "X-RapidAPI-Host"), "aerodatabox.p.rapidapi.com")
    }

    func testNoContentMeansNoFlights() async throws {
        let http = StubHTTP { _ in (204, Data(), [:]) }
        let client = AeroDataBoxClient(marketplace: .apiMarket(key: "k"), http: http)
        let legs = try await client.flights(number: "ua 01234", date: "2026-10-05")
        XCTAssertTrue(legs.isEmpty)
        XCTAssertTrue(http.requests[0].url!.path.hasSuffix("/flights/number/UA1234/2026-10-05"))
    }

    func testMapsAuthAndRateLimitErrors() async {
        for (status, expected) in [(401, ProviderError.unauthorized), (429, .rateLimited(retryAfter: 30))] {
            let http = StubHTTP { _ in (status, Data("nope".utf8), ["Retry-After": "30"]) }
            let client = AeroDataBoxClient(marketplace: .apiMarket(key: "k"), http: http)
            do {
                _ = try await client.flights(number: "UA1", date: "2026-10-05")
                XCTFail("expected \(expected)")
            } catch let error as ProviderError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }
}

final class OpenSkyTests: XCTestCase {
    func testDecodesStateVectorWithZeroTrackAndVerticalRate() throws {
        let states = try OpenSkyDecoder.decodeStates(try Fixture.data("opensky_states"))
        let p = try XCTUnwrap(states.first)
        XCTAssertEqual(p.latitude, 33.9)
        XCTAssertEqual(p.longitude, -94.1)
        XCTAssertEqual(p.altitudeFt, 36000)
        XCTAssertEqual(p.groundSpeedKt, 471)
        XCTAssertEqual(p.trackDeg, 0, "a 0 heading must not be read as a boolean")
        XCTAssertEqual(p.verticalRateFpm, 0)
        XCTAssertFalse(p.onGround)
        XCTAssertEqual(p.reportedAt, Date(timeIntervalSince1970: 1_791_213_610))
    }

    func testNullStatesIsEmpty() throws {
        XCTAssertTrue(try OpenSkyDecoder.decodeStates(try Fixture.data("opensky_states_empty")).isEmpty)
    }

    func testDecodesTrack() throws {
        let track = try OpenSkyDecoder.decodeTrack(try Fixture.data("opensky_track"))
        XCTAssertEqual(track.count, 4)
        XCTAssertTrue(track[0].onGround)
        XCTAssertEqual(track[0].altitudeFt, 0)
        XCTAssertEqual(track[3].altitudeFt, 36000)
        XCTAssertEqual(track[2].trackDeg, 1)
    }

    func testFetchesTokenOnceAndSendsBearer() async throws {
        let states = try Fixture.data("opensky_states")
        let http = StubHTTP { req in
            if req.url!.host == "auth.opensky-network.org" {
                return (200, Data(#"{"access_token":"tok123","expires_in":1800,"token_type":"Bearer"}"#.utf8), [:])
            }
            return (200, states, [:])
        }
        let client = OpenSkyClient(credentials: .init(clientID: "id", clientSecret: "s&cret"), http: http)
        _ = try await client.position(icao24: "A4B3C2")
        _ = try await client.position(icao24: "a4b3c2")
        let reqs = http.requests
        XCTAssertEqual(reqs.filter { $0.url!.host == "auth.opensky-network.org" }.count, 1)
        let body = String(decoding: reqs[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(body, "client_id=id&client_secret=s%26cret&grant_type=client_credentials")
        XCTAssertEqual(reqs[1].value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        XCTAssertEqual(reqs[1].url?.query, "icao24=a4b3c2")
    }

    func testTrack404IsEmpty() async throws {
        let http = StubHTTP { _ in (404, Data(), [:]) }
        let client = OpenSkyClient(credentials: nil, http: http)
        let track = try await client.track(icao24: "abc")
        XCTAssertTrue(track.isEmpty)
    }
}
