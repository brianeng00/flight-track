import FlightCore
import Foundation

/// API keys injected at build time from Secrets.xcconfig via Info.plist.
/// Personal app on your own phone only: keys in the binary are acceptable here,
/// but never commit Secrets.xcconfig (it's gitignored).
enum AppConfig {
    private static func value(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting can arrive literally as "$(NAME)".
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    static var aeroDataBoxMarketplace: AeroDataBoxMarketplace? {
        if let key = value("FTAeroDataBoxAPIMarketKey") { return .apiMarket(key: key) }
        if let key = value("FTAeroDataBoxRapidAPIKey") { return .rapidAPI(key: key) }
        return nil
    }

    static var openSkyCredentials: OpenSkyClient.Credentials? {
        guard let id = value("FTOpenSkyClientID"), let secret = value("FTOpenSkyClientSecret") else { return nil }
        return .init(clientID: id, clientSecret: secret)
    }

    static var isConfigured: Bool { aeroDataBoxMarketplace != nil }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.example.flighttrack" }
    static var refreshTaskID: String { bundleID + ".refresh" }

    /// When this install stops launching (free Apple account profiles last 7 days).
    static var profileExpiry: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return ProvisioningInfo.expirationDate(profileData: data)
    }
}
