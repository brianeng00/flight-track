import FlightCore
import MapKit
import UIKit

/// Renders the route map for the Live Activity once, while the app is in the foreground.
/// The widget can't touch the network, so it reads this file from the App Group instead,
/// and draws the plane on top using route points projected with the same snapshot.
enum MapSnapshotRenderer {
    /// Lock-screen card width is about 360 pt; keep the image modest so the widget loads it fast.
    static let size = CGSize(width: 340, height: 110)

    struct Output {
        var fileName: String
        var route: [RoutePoint]
    }

    static func render(for flight: TrackedFlight) async -> Output? {
        guard let a = flight.departureCoordinate, let b = flight.arrivalCoordinate else { return nil }
        let path = Geo.greatCircle(a, b, count: 16).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 2
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll
        options.region = region(fitting: path)
        options.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            let route = path.map { c -> RoutePoint in
                let p = snapshot.point(for: c)
                return RoutePoint(x: p.x / size.width, y: p.y / size.height)
            }
            guard let data = snapshot.image.jpegData(compressionQuality: 0.7) else { return nil }
            let file = "route-\(flight.id.uuidString).jpg"
            try data.write(to: AppGroup.mapImageURL(named: file), options: .atomic)
            return Output(fileName: file, route: route)
        } catch {
            return nil
        }
    }

    static func delete(for flightID: UUID) {
        try? FileManager.default.removeItem(at: AppGroup.mapImageURL(named: "route-\(flightID.uuidString).jpg"))
    }

    /// Region around the route with padding, stretched to the image's aspect ratio.
    private static func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        var latSpan = (lats.max()! - lats.min()!) * 1.5 + 0.5
        var lonSpan = (lons.max()! - lons.min()!) * 1.3 + 0.5
        // Match the image aspect ratio (lon degrees shrink with cos(lat)).
        let aspect = size.width / size.height
        let k = cos(center.latitude * .pi / 180)
        if lonSpan * k / latSpan < aspect { lonSpan = latSpan * aspect / k } else { latSpan = lonSpan * k / aspect }
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: min(latSpan, 170), longitudeDelta: min(lonSpan, 350)))
    }
}
