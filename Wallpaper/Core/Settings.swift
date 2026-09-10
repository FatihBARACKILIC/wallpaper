import Foundation

/// How often the wallpaper changes. `.manual` means only the menu bar button
/// changes it.
enum ChangeInterval: Codable, Hashable {
    case manual
    case seconds(Int)

    static let presets: [ChangeInterval] = [
        .seconds(5 * 60),
        .seconds(15 * 60),
        .seconds(30 * 60),
        .seconds(60 * 60),
        .seconds(3 * 60 * 60),
        .seconds(6 * 60 * 60),
        .seconds(12 * 60 * 60),
        .seconds(24 * 60 * 60),
        .seconds(7 * 24 * 60 * 60),
        .manual,
    ]

    /// `nil` for `.manual` — nothing to schedule.
    var duration: TimeInterval? {
        switch self {
        case .manual: nil
        case .seconds(let value): TimeInterval(value)
        }
    }

    var displayName: String {
        guard case .seconds(let value) = self else { return "Manually only" }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(value)) ?? "\(value)s"
    }

    /// Roughly how many API requests this interval costs per hour, used to warn
    /// the user before they outrun a 50/hour demo key.
    func estimatedRequestsPerHour(screenCount: Int) -> Int {
        guard let duration, duration > 0 else { return 0 }
        let changesPerHour = 3600.0 / duration
        return Int((changesPerHour * Double(screenCount) * 2).rounded(.up))
    }
}

enum MonitorMode: String, Codable, CaseIterable {
    case sameOnAllScreens
    case differentPerScreen

    var displayName: String {
        switch self {
        case .sameOnAllScreens: "Same photo on every screen"
        case .differentPerScreen: "A different photo per screen"
        }
    }
}

/// Cache cap. Both limits apply at once; whichever fills first triggers
/// eviction. Turning `isEnabled` off disables eviction entirely.
struct StorageLimit: Codable, Hashable {
    var isEnabled = true
    var maxPhotos = 100
    var maxBytes: Int64 = 1_073_741_824  // 1 GB

    static let unlimited = StorageLimit(isEnabled: false)
}

struct AppSettings: Codable, Hashable {
    var sources: [Source] = []
    /// The name this user registered their application under on Unsplash.
    /// Used as `utm_source` in attribution links, as the guidelines require.
    var applicationName = UnsplashAttribution.defaultApplicationName
    var interval: ChangeInterval = .seconds(60 * 60)
    var monitorMode: MonitorMode = .sameOnAllScreens
    var storageLimit = StorageLimit()
    var fadeTransition = true
    var launchAtLogin = false
    var hasCompletedOnboarding = false
}

/// Single source of truth for user preferences. Preferences live in
/// UserDefaults; the Access Key lives in the Keychain and is never persisted
/// here.
@Observable
final class SettingsStore {
    private static let defaultsKey = "settings"

    private(set) var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }

        UnsplashAttribution.applicationName = settings.applicationName
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        UnsplashAttribution.applicationName = copy.applicationName
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Access key

    var accessKey: String? {
        Keychain.read()
    }

    var hasAccessKey: Bool {
        accessKey?.isEmpty == false
    }

    func setAccessKey(_ key: String) throws {
        try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func clearAccessKey() {
        Keychain.delete()
    }
}
