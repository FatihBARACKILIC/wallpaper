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
                    }
                }
            }
        }
    }

    /// Who to credit, which depends on where the photo came from. Unsplash's
    /// wording and links are fixed by its API guidelines; NASA asks only that
    /// a copyrighted picture names its holder, and a file of the user's own
    /// needs no credit at all.
    @ViewBuilder
    private func attribution(for artwork: Artwork) -> some View {
        switch artwork.provider {
        case .unsplash:
            unsplashAttribution(for: artwork)
        case .apod:
            apodAttribution(for: artwork)
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

    /// A gauge per API actually in use. A folder-only setup makes no requests
    /// at all, so it gets no gauge.
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

            Text(nextChangeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            return "Add a source to start rotating wallpapers — an Unsplash topic, a folder of your own photos, or NASA's picture of the day."
        }
        return WallpaperManager.SetupError
            .noUsableSources(manager.settings.settings.sources)
            .localizedDescription
    }

    private var isOffline: Bool {
        if case .waitingForNetwork = manager.status { return true }
        return false
    }

    private var nextChangeDescription: String {
        if manager.status == .working { return "Changing…" }
        guard let next = manager.scheduler.nextChangeDate else { return "Changes manually only" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Next change \(formatter.localizedString(for: next, relativeTo: Date()))"
    }
}
