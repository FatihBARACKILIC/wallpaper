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
    ///
    /// One change is one `/photos/random` call — `count` fetches every photo at
    /// once — plus one download report per photo, which the API guidelines
    /// require and which counts against the limit. The image bytes come from
    /// the CDN and do not count.
    func estimatedRequestsPerHour(photosPerChange: Int) -> Int {
        guard let duration, duration > 0 else { return 0 }
        let changesPerHour = 3600.0 / duration
        return Int((changesPerHour * Double(1 + max(1, photosPerChange))).rounded(.up))
    }
}

/// How large a photo to download.
enum PhotoResolution: String, Codable, CaseIterable {
    /// The biggest attached screen. Anything smaller crops from it.
    case largestScreen
    /// Largest width *and* largest height across screens, so no screen ever
    /// has to scale the photo up.
    case coverAllScreens
    /// The photo as Unsplash has it. Much larger files.
    case original

    var displayName: String {
        switch self {
        case .largestScreen: "Match the largest display"
        case .coverAllScreens: "Fit every display automatically"
        case .original: "Full resolution"
        }
    }

    var explanation: String {
        switch self {
        case .largestScreen:
            "Sized to your biggest screen. About 1 MB per photo."
        case .coverAllScreens:
            "Sized so no display ever scales a photo up. Slightly larger files than the option above."
        case .original:
            "Downloads photos at their original size — often 10–30 MB each, filling the storage limit far faster."
        }
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
    var photoResolution: PhotoResolution = .largestScreen
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
