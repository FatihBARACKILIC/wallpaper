import SwiftUI

/// The menu bar panel. Nothing here exists while the menu is closed, which is
/// what keeps the app's idle cost at zero.
struct MenuContent: View {
    @Bindable var manager: WallpaperManager

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.isReady {
                currentPhoto
                Divider()
                actions
                recent
                quotas
            } else {
                setupPrompt
            }

            if let notice = manager.notice {
                Divider()
                Label(notice, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = manager.status.errorMessage {
                Divider()
                Label(message, systemImage: isOffline ? "wifi.slash" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(isOffline ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Sections

    @ViewBuilder
    private var currentPhoto: some View {
        if manager.currentArtworks.isEmpty {
            Text("No wallpaper set yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            // Every photo in use has to be credited, not just the first — in
            // per-screen mode each display carries a different photographer.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(manager.currentArtworks.enumerated()), id: \.offset) { index, artwork in
                    VStack(alignment: .leading, spacing: 2) {
                        if let screen = screenName(at: index) {
                            Text(screen)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        attribution(for: artwork)
                        verdict(for: artwork)
                    }
                }
            }
        }
    }

    /// The two things the user can say about the photo in front of them: keep
    /// it, or never see it again. Both are per photo rather than per change —
    /// in per-screen mode only one of the displays may be the offender.
    private func verdict(for artwork: Artwork) -> some View {
        let isPinned = manager.library.isFavorite(artwork)

        return HStack(spacing: 12) {
            Button {
                manager.toggleFavorite(artwork)
            } label: {
                Label(isPinned ? "Pinned" : "Pin this", systemImage: isPinned ? "pin.fill" : "pin")
            }
            .help(isPinned
                  ? "Pinned: this photo is never deleted to make room, and you can put it back any time."
                  : "Keep this photo. It is never deleted to make room, and you can put it back any time.")

            Button {
                Task { await manager.block(artwork) }
            } label: {
                Label("Never show again", systemImage: "hand.raised")
            }
            .help("Never pick this photo again, and change the wallpaper now.")
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.top, 2)
        .disabled(manager.status == .working)
    }

    /// The wallpapers before this one, newest first. Collapsed by default: the
    /// menu is mostly opened to see who took the photo on screen, not to browse.
    @ViewBuilder
    private var recent: some View {
        // Whatever is on screen is not something to go back to, and it is
        // credited a few lines above already.
        let onScreen = Set(manager.currentArtworks.map(\.key))
        let entries = manager.library.history.filter { !onScreen.contains($0.id) }.prefix(8)

        if !entries.isEmpty {
            Divider()
            DisclosureGroup("Recent wallpapers") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Button {
                                Task { await manager.apply(entry.artwork) }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.artwork.shortLabel)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text(entry.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(manager.status == .working)

                            // Not disabled with the rest: looking at where a
                            // photo came from costs nothing and is worth doing
                            // while a change is still running.
                            SourceLink(artwork: entry.artwork)
                        }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    /// Who to credit, which depends on where the photo came from. Unsplash's
    /// wording and links are fixed by its API guidelines; NASA asks only that
    /// a copyrighted picture names its holder; Wallhaven is user uploads, so
    /// the most it can offer is the link the uploader credited; and a file of
    /// the user's own needs no credit at all.
    @ViewBuilder
    private func attribution(for artwork: Artwork) -> some View {
        switch artwork.provider {
        case .unsplash:
            unsplashAttribution(for: artwork)
        case .apod:
            apodAttribution(for: artwork)
        case .wallhaven:
            wallhavenAttribution(for: artwork)
        case .local:
            localAttribution(for: artwork)
        }
    }

    /// "Photo by <name> on Unsplash", both links carrying UTM parameters — the
    /// attribution the API guidelines require.
    private func unsplashAttribution(for artwork: Artwork) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("Photo by ")
                if let creator = artwork.creator {
                    if let creatorURL = artwork.creatorURL {
                        Link(creator, destination: creatorURL)
                    } else {
                        Text(creator)
                    }
                }
                Text(" on ")
                Link("Unsplash", destination: UnsplashAttribution.homeURL)
            }
            .font(.callout)

            if let webURL = artwork.webURL {
                Link("View this photo", destination: webURL)
                    .font(.caption)
            }
        }
    }

    private func apodAttribution(for artwork: Artwork) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artwork.title ?? "Astronomy Picture of the Day")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            // Only a copyrighted picture carries a holder; NASA's own images
            // are public domain and name nobody.
            if let creator = artwork.creator {
                Text("© \(creator)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let webURL = artwork.webURL {
                Link("NASA Astronomy Picture of the Day", destination: webURL)
                    .font(.caption)
            }
        }
    }

    /// Wallhaven names no photographer: a search answer carries neither an
    /// uploader nor a caption. What it sometimes does carry is the link the
    /// uploader credited the image to, which is the closest thing to an author
    /// there is — so it is offered when it exists and nothing is claimed when
    /// it does not.
    private func wallhavenAttribution(for artwork: Artwork) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Wallpaper from Wallhaven")
                .font(.callout)

            if let webURL = artwork.webURL {
                Link("View this wallpaper", destination: webURL)
                    .font(.caption)
            }

            if let originalURL = artwork.creatorURL {
                Link("Original source", destination: originalURL)
                    .font(.caption)
            }
        }
    }

    private func localAttribution(for artwork: Artwork) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artwork.title ?? artwork.origin.url.lastPathComponent)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([artwork.origin.url])
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    /// Only worth labelling when more than one photo is on screen at once.
    private func screenName(at index: Int) -> String? {
        guard manager.currentArtworks.count > 1 else { return nil }
        let screens = NSScreen.screens
        return index < screens.count ? screens[index].localizedName : nil
    }

    /// A gauge per API with an hourly quota worth watching. A folder-only setup
    /// makes no requests at all, so it gets no gauge — and neither does
    /// Wallhaven, whose 45-a-minute rolling limit one request per change cannot
    /// come near and whose reset `RateLimit` would describe wrongly.
    @ViewBuilder
    private var quotas: some View {
        let kinds = Set(manager.settings.settings.sources.map(\.kind.provider))

        if kinds.contains(.unsplash) {
            Divider()
            RateLimitGauge(name: "Unsplash", rateLimit: manager.client.rateLimit)
        }
        if kinds.contains(.apod) {
            Divider()
            RateLimitGauge(name: "NASA", rateLimit: manager.nasa.rateLimit)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await manager.changeNow() }
            } label: {
                Label("Change wallpaper now", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("r")
            .disabled(manager.status == .working)

            Button {
                Task { await manager.goBack() }
            } label: {
                Label("Previous wallpaper", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("[")
            .disabled(manager.status == .working || !manager.canGoBack)

            NextChangeLabel(
                nextChangeDate: manager.scheduler.nextChangeDate,
                isChanging: manager.status == .working
            )

            if let sky = manager.currentSunlight {
                Label(skyDescription(sky), systemImage: skySymbol(sky))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup isn't finished")
                .font(.callout.weight(.medium))
            Text(setupMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Finish setup…") {
                openWindow(id: OnboardingWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    // MARK: - Helpers

    /// Sources with no key are the more useful thing to say: an empty list
    /// needs a source, and a list that is all Unsplash needs the key.
    private var setupMessage: String {
        guard !manager.settings.settings.sources.isEmpty else {
            return "Add a source to start rotating wallpapers — an Unsplash topic, a Wallhaven search, a folder of your own photos, or NASA's picture of the day."
        }
        return SetupError
            .noUsableSources(manager.settings.settings.sources)
            .localizedDescription
    }

    /// Only shown when the user turned sky matching on, so it explains a
    /// setting they chose rather than announcing one they did not.
    private func skyDescription(_ sky: Sunlight) -> String {
        switch sky.phase {
        case .day: "Daylight — picking brighter photos"
        case .twilight: "Twilight — picking mid-toned photos"
        case .night: "Night — picking darker photos"
        }
    }

    private func skySymbol(_ sky: Sunlight) -> String {
        switch sky.phase {
        case .day: "sun.max"
        case .twilight: "sun.horizon"
        case .night: "moon.stars"
        }
    }

    private var isOffline: Bool {
        if case .waitingForNetwork = manager.status { return true }
        return false
    }

}
