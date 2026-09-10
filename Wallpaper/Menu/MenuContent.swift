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
                Divider()
                RateLimitGauge(rateLimit: manager.client.rateLimit)
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
        if manager.currentPhotos.isEmpty {
            Text("No wallpaper set yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            // Every photo in use has to be credited, not just the first — in
            // per-screen mode each display carries a different photographer.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(manager.currentPhotos.enumerated()), id: \.offset) { index, photo in
                    VStack(alignment: .leading, spacing: 2) {
                        if let screen = screenName(at: index) {
                            Text(screen)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        attribution(for: photo)
                    }
                }
            }
        }
    }

    /// "Photo by <name> on Unsplash", both links carrying UTM parameters — the
    /// attribution the API guidelines require.
    private func attribution(for photo: Photo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("Photo by ")
                if let photographerURL = photo.photographerURL {
                    Link(photo.user.name, destination: photographerURL)
                } else {
                    Text(photo.user.name)
                }
                Text(" on ")
                Link("Unsplash", destination: UnsplashAttribution.homeURL)
            }
            .font(.callout)

            if let webURL = photo.webURL {
                Link("View this photo", destination: webURL)
                    .font(.caption)
            }
        }
    }

    /// Only worth labelling when more than one photo is on screen at once.
    private func screenName(at index: Int) -> String? {
        guard manager.currentPhotos.count > 1 else { return nil }
        let screens = NSScreen.screens
        return index < screens.count ? screens[index].localizedName : nil
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
            Text(manager.settings.hasAccessKey
                 ? "Add at least one source to start rotating wallpapers."
                 : "Add your Unsplash Access Key to get started.")
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
