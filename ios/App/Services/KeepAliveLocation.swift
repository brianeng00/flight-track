import CoreLocation
import FlightCore
import Foundation

/// Free-account workaround: while location updates run with the `location` background mode,
/// iOS keeps the app alive, so it can keep polling and updating the Live Activity itself.
/// Costs battery, so it only runs inside a flight's active window.
///
/// Bonus: on board, GPS still works in airplane mode, so fixes also move the plane
/// on the Live Activity with no internet at all.
@MainActor
final class KeepAliveLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private(set) var isRunning = false
    /// Called for every usable fix, already converted to a `LivePosition` from the device.
    var onFix: ((LivePosition) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = 200
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Call from the foreground. With iOS 17's background activity session, When In Use
    /// permission is enough to keep receiving updates after you lock the phone.
    func start() {
        guard !isRunning else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        backgroundSession = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        isRunning = false
    }

    /// Precise GPS in the air (to place the plane), coarse on the ground (battery).
    func setInFlight(_ inFlight: Bool) {
        let accuracy = inFlight ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        if manager.desiredAccuracy != accuracy { manager.desiredAccuracy = accuracy }
        manager.distanceFilter = inFlight ? 500 : 200
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 1000 else { return }
        let fix = LivePosition(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitudeFt: loc.verticalAccuracy >= 0 ? Units.metersToFeet(loc.altitude) : nil,
            groundSpeedKt: loc.speed >= 0 ? Units.msToKnots(loc.speed) : nil,
            trackDeg: loc.course >= 0 ? loc.course : nil,
            verticalRateFpm: nil,
            onGround: loc.speed >= 0 && loc.speed < 40, // under ~78 kt is not flying
            reportedAt: loc.timestamp,
            source: .device)
        Task { @MainActor in self.onFix?(fix) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.onAuthorizationChange?(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix (e.g. deep in a terminal). The session stays alive; nothing to do.
    }
}
