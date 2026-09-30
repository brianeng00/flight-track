import FlightCore
import Foundation
import UserNotifications

/// Local notifications stand in for push on a free Apple account. They fire from this
/// process, so they only arrive while the app is alive (the keep-alive's job).
final class LocalNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String {
        case flightEvent
        case startTracking
        case reinstall
    }

    static let flightIDKey = "flightID"
    static let kindKey = "kind"

    private let center = UNUserNotificationCenter.current()
    /// Called on the main actor when a notification is tapped.
    var onOpen: (@MainActor (_ kind: Kind, _ flightID: UUID?) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(_ content: AlertContent, flightID: UUID, eventKey: String) {
        let c = UNMutableNotificationContent()
        c.title = content.title
        c.body = content.body
        c.threadIdentifier = content.threadID
        c.sound = .default
        // Time Sensitive needs a paid-account entitlement; `.active` is the best a free account gets.
        c.interruptionLevel = .active
        c.userInfo = [Self.kindKey: Kind.flightEvent.rawValue, Self.flightIDKey: flightID.uuidString]
        let request = UNNotificationRequest(identifier: "\(flightID.uuidString).\(eventKey)", content: c, trigger: nil)
        center.add(request)
    }

    /// "Start live tracking" at T-3h. Tapping it brings the app forward, which is when
    /// ActivityKit allows starting the Live Activity.
    func scheduleStartReminder(for flight: TrackedFlight, at date: Date) {
        let id = "\(flight.id.uuidString).start"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard date > Date() else { return }
        let c = UNMutableNotificationContent()
        let s = flight.snapshot
        c.title = "Start live tracking \(s.number)"
        c.body = "\(s.departure.airport.code) → \(s.arrival.airport.code) departs \(FlightFormat.localTime(s.departure.times.bestGate, timeZone: s.departure.airport.timeZone)). Tap to put it on your Lock Screen."
        c.sound = .default
        c.userInfo = [Self.kindKey: Kind.startTracking.rawValue, Self.flightIDKey: flight.id.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
    }

    func cancelReminders(for flightID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["\(flightID.uuidString).start"])
    }

    /// One day before the free-account profile expires.
    func scheduleReinstallReminder(expiry: Date) {
        let id = "reinstall"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let fire = expiry.addingTimeInterval(-24 * 3600)
        guard fire > Date() else { return }
        let c = UNMutableNotificationContent()
        c.title = "Reinstall FlightTrack from Xcode"
        c.body = "This install stops launching in about a day (free Apple account limit). Plug into your Mac and press Run."
        c.userInfo = [Self.kindKey: Kind.reinstall.rawValue]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let kind = (info[Self.kindKey] as? String).flatMap(Kind.init(rawValue:)) ?? .flightEvent
        let id = (info[Self.flightIDKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run { onOpen?(kind, id) }
    }
}
