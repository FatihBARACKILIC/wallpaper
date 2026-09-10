import AppKit

/// Applies wallpapers to the attached screens.
///
/// Note: `NSWorkspace.desktopImageURL(for:)` lags behind writes — macOS hands
/// the change to a separate wallpaper agent, so reading the value back right
/// after setting it returns the *previous* URL. Success is therefore measured
/// by `setDesktopImageURL` not throwing; never verify with the getter.
enum WallpaperSetter {
    /// Pixel dimensions of each screen, used to request a correctly sized
    /// download instead of a full-resolution original.
    static func screenPixelSizes() -> [CGSize] {
        NSScreen.screens.map { screen in
            let points = screen.frame.size
            let scale = screen.backingScaleFactor
            return CGSize(width: points.width * scale, height: points.height * scale)
        }
    }

    static var screenCount: Int { NSScreen.screens.count }

    /// The biggest attached screen, by pixel count.
    static func largestScreenPixelSize() -> CGSize {
        screenPixelSizes().max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 2560, height: 1440)
    }

    /// The smallest size that can fill every screen without being scaled up.
    ///
    /// Not the largest screen by area: an ultra-wide monitor can beat a Retina
    /// display on area while being shorter, and a photo sized for it would be
    /// stretched on the taller screen. Taking the largest width *and* the
    /// largest height means every screen crops rather than upscales.
    static func coveringPixelSize() -> CGSize {
        let sizes = screenPixelSizes()
        guard !sizes.isEmpty else { return CGSize(width: 2560, height: 1440) }

        return CGSize(
            width: sizes.map(\.width).max() ?? 2560,
            height: sizes.map(\.height).max() ?? 1440
        )
    }

    /// Sets one photo on every screen.
    static func apply(_ url: URL) throws {
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    /// Sets a different photo per screen. `urls` is indexed by screen order; a
    /// short array repeats its last entry so a newly attached display still
    /// gets a wallpaper.
    static func apply(perScreen urls: [URL]) throws {
        guard let fallback = urls.last else { return }

        for (index, screen) in NSScreen.screens.enumerated() {
            let url = index < urls.count ? urls[index] : fallback
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    /// The wallpapers currently on screen. These must never be evicted from the
    /// cache — deleting them would blank the desktop.
    static func currentWallpaperURLs() -> Set<URL> {
        Set(NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) })
    }
}
