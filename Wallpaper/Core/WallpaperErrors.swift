import Foundation

// The three ways a wallpaper change can fail that are the app's own rather than
// a provider's. Lifted out of `WallpaperManager` because they are what the
// menu, the onboarding window and the recovery table all speak in — none of
// which needs the manager itself.

/// The app is configured, but not in a way it can act on.
nonisolated enum SetupError: LocalizedError {
    /// Sources exist, but every one of them is waiting on a key.
    case noUsableSources([Source])

    var errorDescription: String? {
        switch self {
        case .noUsableSources(let sources):
            let needed = Set(sources.map(\.kind.provider))
            return switch (needed.contains(.unsplash), needed.contains(.apod)) {
            case (true, true):
                "Your sources need an Unsplash Access Key and a NASA API key. Add them in Settings."
            case (false, true):
                "The NASA APOD source needs a NASA API key. Add one in Settings."
            default:
                "Your Unsplash sources need an Access Key. Add one in Settings."
            }
        }
    }
}

/// A source offered photos, but not ones that could be used.
nonisolated enum PickError: LocalizedError {
    /// Every photo in the draw was on the user's "never show again" list.
    /// The default recovery — retry with backoff — is the right one: the
    /// next draw from an API is a different set of photos.
    case everythingBlocked(Source)
    /// A remembered photo whose file the user has since deleted. Only a
    /// photo from one of their own folders can be lost this way; a
    /// downloaded one is fetched again.
    case fileGone(Artwork)

    var errorDescription: String? {
        switch self {
        case .everythingBlocked(let source):
            "Every photo \(source.shortLabel) offered is one you asked never to see again."
        case .fileGone(let artwork):
            "\(artwork.shortLabel) isn't on this Mac any more."
        }
    }
}

/// The connection is the user's own data allowance and
/// `pauseOnExpensiveNetwork` is on, so nothing may be downloaded. Not a
/// failure — a wait, which is why it recovers through `.waitForNetwork`.
nonisolated enum MeteredNetworkError: LocalizedError {
    case expensive
    case constrained

    var errorDescription: String? {
        switch self {
        case .expensive: "On cellular or a hotspot — waiting for Wi-Fi."
        case .constrained: "Low Data Mode is on — waiting for a full-speed network."
        }
    }

    /// Said instead when a photo already on disk could be shown.
    var cacheNotice: String {
        switch self {
        case .expensive: "On a hotspot — showing a photo you already have."
        case .constrained: "Low Data Mode — showing a photo you already have."
        }
    }
}
