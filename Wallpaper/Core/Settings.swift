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
    /// `costPerChange` comes from `Artwork.Provider.requestCost`.
    func estimatedRequestsPerHour(costPerChange: Int) -> Int {
        guard let duration, duration > 0, costPerChange > 0 else { return 0 }
        let changesPerHour = 3600.0 / duration
        return Int((changesPerHour * Double(costPerChange)).rounded(.up))
    }
}

extension Artwork.Provider {
    /// Whether a change from this provider spends the user's data allowance.
    /// A folder on this Mac does not: the files are already here.
    var needsDownload: Bool {
        switch self {
        case .unsplash, .apod: true
        case .local: false
        }
    }

    /// What one wallpaper change costs this provider in API requests.
    ///
    /// Unsplash is `1 + N`: a single `/photos/random` call fetches the whole
    /// batch, and then each photo needs the download report the API guidelines
    /// require. APOD is flat 1 — it also returns the whole batch at once, and
    /// has nothing to report afterwards. A folder on this Mac costs nothing;
    /// the image bytes never count for any of them.
    func requestCost(photosPerChange: Int) -> Int {
        switch self {
        case .unsplash: 1 + max(1, photosPerChange)
        case .apod: 1
        case .local: 0
        }
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
    /// Downloading over a hotspot is the user's own data allowance. When this
    /// is on, a change on an expensive or constrained path uses only what costs
    /// nothing — a folder on this Mac, or a photo already downloaded.
    var pauseOnExpensiveNetwork = true
    var hasCompletedOnboarding = false

    init() {}

    /// Decoded field by field so that a stored settings blob written by an
    /// older build — one that has never heard of a field added since — still
    /// loads. The synthesized decoder throws `keyNotFound` for a missing key
    /// even when the property has a default, and `SettingsStore` answers a
    /// decode failure by falling back to `AppSettings()`: every source, the
    /// interval and the onboarding flag would be silently wiped. Any field
    /// added here must be read with `decodeIfPresent`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()

        sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? fallback.sources
        applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName)
            ?? fallback.applicationName
        interval = try container.decodeIfPresent(ChangeInterval.self, forKey: .interval) ?? fallback.interval
        monitorMode = try container.decodeIfPresent(MonitorMode.self, forKey: .monitorMode) ?? fallback.monitorMode
        photoResolution = try container.decodeIfPresent(PhotoResolution.self, forKey: .photoResolution)
            ?? fallback.photoResolution
        storageLimit = try container.decodeIfPresent(StorageLimit.self, forKey: .storageLimit)
            ?? fallback.storageLimit
        fadeTransition = try container.decodeIfPresent(Bool.self, forKey: .fadeTransition) ?? fallback.fadeTransition
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        pauseOnExpensiveNetwork = try container.decodeIfPresent(Bool.self, forKey: .pauseOnExpensiveNetwork)
            ?? fallback.pauseOnExpensiveNetwork
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
            ?? fallback.hasCompletedOnboarding
    }
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

    /// Whether the Unsplash Access Key is in the keychain.
    ///
    /// Mirrored here rather than read straight from the keychain each time,
    /// because the keychain is not observable: a Continue button that asks
    /// the keychain directly is never told the key has arrived, and stays
    /// disabled until the view is built again. Every write goes through this
    /// type so the mirror cannot drift.
    private(set) var hasAccessKey: Bool

    /// Whether the NASA API key is in the keychain. Mirrored for the same
    /// reason as `hasAccessKey`.
    private(set) var hasNASAKey: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasAccessKey = Keychain.unsplashAccessKey.read()?.isEmpty == false
        self.hasNASAKey = Keychain.nasaAPIKey.read()?.isEmpty == false

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

    // MARK: - Keys

    var accessKey: String? {
        Keychain.unsplashAccessKey.read()
    }

    func setAccessKey(_ key: String) throws {
        try Keychain.unsplashAccessKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAccessKey = true
    }

    func clearAccessKey() {
        Keychain.unsplashAccessKey.delete()
        hasAccessKey = false
    }

    var nasaKey: String? {
        Keychain.nasaAPIKey.read()
    }

    func setNASAKey(_ key: String) throws {
        try Keychain.nasaAPIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasNASAKey = true
    }

    func clearNASAKey() {
        Keychain.nasaAPIKey.delete()
        hasNASAKey = false
    }

    /// Whether `source` can actually be used right now.
    ///
    /// A folder always can — it needs no key and no network. The two API
    /// sources need their own key, which is why the app no longer insists on an
    /// Unsplash key before it will start: a folder-only setup is a complete one.
    func canUse(_ source: Source) -> Bool {
        switch source.kind.provider {
        case .unsplash: hasAccessKey
        case .apod: hasNASAKey
        case .local: true
        }
    }

    /// The sources that can be drawn from right now.
    var usableSources: [Source] {
        settings.sources.filter(canUse)
    }
}
