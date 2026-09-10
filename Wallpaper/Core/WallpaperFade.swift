import AppKit

/// Cross-fades between wallpapers.
///
/// `setDesktopImageURL` swaps the picture instantly, so the fade is done with a
/// borderless window per screen sitting just above the wallpaper and below the
/// desktop icons: the incoming photo fades in over the old one, the real
/// wallpaper is swapped underneath while it is fully covered, and the window
/// then goes away revealing an identical picture.
@MainActor
enum WallpaperFade {
    static let duration: TimeInterval = 0.6

    /// macOS hands the wallpaper to a separate agent, so the swap underneath is
    /// not instant. Hold the cover a little longer or the old picture flashes.
    private static let settleDelay: TimeInterval = 0.5

    /// - Parameters:
    ///   - pairs: the incoming photo for each screen.
    ///   - apply: sets the real wallpaper; runs while the screens are covered.
    static func run(_ pairs: [(screen: NSScreen, url: URL)], apply: () throws -> Void) async throws {
        let windows = pairs.compactMap(cover(screen:url:))
        guard !windows.isEmpty else {
            try apply()
            return
        }

        defer {
            for window in windows { window.orderOut(nil) }
        }

        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for window in windows { window.animator().alphaValue = 1 }
            } completionHandler: {
                continuation.resume()
            }
        }

        try apply()
        try? await Task.sleep(for: .seconds(settleDelay))
    }

    private static func cover(screen: NSScreen, url: URL) -> NSWindow? {
        guard let image = NSImage(contentsOf: url) else { return nil }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // Above the wallpaper, below the desktop icons, and out of the way of
        // clicks, Mission Control and window cycling.
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0
        window.setFrame(screen.frame, display: false)

        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = image
        // The photo was downloaded at this screen's size, so filling the frame
        // matches what the wallpaper itself will show.
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view

        window.orderFrontRegardless()
        return window
    }
}
