import SwiftUI

struct SettingsView: View {
    @Bindable var manager: WallpaperManager

    var body: some View {
        TabView {
            GeneralSettings(manager: manager)
                .tabItem { Label("General", systemImage: "gearshape") }

            SourcesSettings(manager: manager)
                .tabItem { Label("Sources", systemImage: "photo.stack") }

            LibrarySettings(manager: manager)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            AccountSettings(manager: manager)
                .tabItem { Label("Account", systemImage: "key") }

            StorageSettings(manager: manager)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var manager: WallpaperManager
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var isUninstalling = false

    var body: some View {
        Form {
            Section {
                IntervalPicker(settings: manager.settings)
                MonitorModePicker(settings: manager.settings)

                ResolutionPicker(settings: manager.settings)

                Toggle("Fade between wallpapers", isOn: Binding(
                    get: { manager.settings.settings.fadeTransition },
                    set: { new in manager.settings.update { $0.fadeTransition = new } }
                ))
            }

            SunlightSection(manager: manager)

            Section {
                Toggle("Pause downloads on cellular and hotspots", isOn: Binding(
                    get: { manager.settings.settings.pauseOnExpensiveNetwork },
                    set: { new in manager.settings.update { $0.pauseOnExpensiveNetwork = new } }
                ))
            } footer: {
                Text("Photo folders on this Mac keep rotating, and so do photos already downloaded — only new ones wait for Wi-Fi. macOS spots an iPhone hotspot by itself. An Android one looks like ordinary Wi-Fi, so switch on Low Data Mode for it in System Settings \u{203A} Wi-Fi \u{203A} Details.")
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            manager.settings.update { $0.launchAtLogin = enabled }
                            loginError = nil
                        } catch {
                            // Revert so the toggle never lies about the real state.
                            launchAtLogin = LoginItem.isEnabled
                            loginError = error.localizedDescription
                        }
                    }

                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button("Uninstall Wallpaper…", role: .destructive) { isUninstalling = true }
            } footer: {
                Text("Removes the downloaded photos, your settings and your Access Key, so nothing is left behind on this Mac.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: manager.settings.settings.interval) { manager.intervalChanged() }
        .sheet(isPresented: $isUninstalling) {
            UninstallSheet(manager: manager)
        }
    }
}

/// How large a photo to download. Bigger means better on a future larger
/// display, and a storage limit that fills much faster.
private struct ResolutionPicker: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Picker("Download size", selection: Binding(
            get: { settings.settings.photoResolution },
            set: { new in settings.update { $0.photoResolution = new } }
        )) {
            ForEach(PhotoResolution.allCases, id: \.self) { resolution in
                Text(resolution.displayName).tag(resolution)
            }
        }

        Text(settings.settings.photoResolution.explanation)
            .font(.caption)
            .foregroundStyle(settings.settings.photoResolution == .original ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sources

private struct SourcesSettings: View {
    @Bindable var manager: WallpaperManager

    var body: some View {
        VStack(alignment: .leading) {
            SourceEditor(settings: manager.settings, client: manager.client, wallhaven: manager.wallhaven)
        }
        .padding(20)
    }
}

// MARK: - History, pins and blocks

/// The photos the app remembers: the last 50 wallpapers, the pinned ones and
/// the ones the user asked never to see again.
///
/// Text only, no thumbnails, on purpose. Fifty decoded images is exactly the
/// kind of cost this app is built not to have, and the rows carry everything
/// needed to recognise a photo: what it is called, who made it and when it was
/// on screen.
private struct LibrarySettings: View {
    @Bindable var manager: WallpaperManager

    @State private var shelf: Shelf = .recent
    @State private var isConfirmingClear = false

    private enum Shelf: String, CaseIterable, Identifiable {
        case recent
        case pinned
        case blocked

        var id: Self { self }

        var displayName: String {
            switch self {
            case .recent: "Recent"
            case .pinned: "Pinned"
            case .blocked: "Never show"
            }
        }

        var emptyMessage: String {
            switch self {
            case .recent: "No wallpapers yet. The last \(PhotoLibrary.historyLimit) will be listed here."
            case .pinned: "Nothing pinned. Pin a photo from the menu bar to keep it out of the way of the storage limit."
            case .blocked: "Nothing blocked. \"Never show again\" in the menu bar puts a photo here."
            }
        }
    }

    private var entries: [PhotoLibrary.Entry] {
        switch shelf {
        case .recent: manager.library.history
        case .pinned: manager.library.favorites
        case .blocked: manager.library.blocked
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Shelf", selection: $shelf) {
                ForEach(Shelf.allCases) { shelf in
                    Text(shelf.displayName).tag(shelf)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if entries.isEmpty {
                Spacer()
                Text(shelf.emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                List(entries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            footer
        }
        .padding(20)
        .confirmationDialog("Clear the history?", isPresented: $isConfirmingClear) {
            Button("Clear", role: .destructive) { manager.library.clearHistory() }
        } message: {
            Text("Forgets the last \(manager.library.history.count) wallpapers. The photos themselves are not deleted, and pinned photos stay pinned.")
        }
    }

    private func row(_ entry: PhotoLibrary.Entry) -> some View {
        let artwork = entry.artwork

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artwork.shortLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // Offered on every shelf, the blocked one included: "what was that
            // photo I rejected?" is a fair question.
            SourceLink(artwork: artwork)

            if shelf == .blocked {
                Button("Unblock") { manager.unblock(artwork) }
            } else {
                Button {
                    Task { await manager.apply(artwork) }
                } label: {
                    Image(systemName: "arrow.up.left.square")
                }
                .help("Put this photo back on the desktop")
                .disabled(isGone(artwork) || manager.status == .working)

                Button {
                    manager.toggleFavorite(artwork)
                } label: {
                    Image(systemName: manager.library.isFavorite(artwork) ? "pin.fill" : "pin")
                }
                .help(manager.library.isFavorite(artwork) ? "Unpin" : "Pin: never delete this photo to make room")

                Button {
                    Task { await manager.block(artwork) }
                } label: {
                    Image(systemName: "hand.raised")
                }
                .help("Never show this photo again")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    /// Where the photo came from and when it was last on screen — plus the one
    /// thing that can go wrong: a file of the user's own that they have since
    /// deleted. A downloaded photo is simply fetched again, so it never needs
    /// saying for those.
    private func subtitle(for entry: PhotoLibrary.Entry) -> String {
        var parts = [entry.artwork.provider.displayName]

        if let creator = entry.artwork.creator, creator != entry.artwork.shortLabel {
            parts.append(creator)
        }
        parts.append(entry.date.formatted(date: .abbreviated, time: .shortened))

        if isGone(entry.artwork) {
            parts.append("not on this Mac any more")
        }
        return parts.joined(separator: " · ")
    }

    private func isGone(_ artwork: Artwork) -> Bool {
        guard case .localFile(let url) = artwork.origin else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    @ViewBuilder
    private var footer: some View {
        switch shelf {
        case .recent:
            HStack {
                Text("The last \(PhotoLibrary.historyLimit) wallpapers. \u{2318}[ in the menu bar steps back through them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { isConfirmingClear = true }
                    .disabled(manager.library.history.isEmpty)
            }
        case .pinned:
            Text("Pinned photos are never deleted to make room, so they keep counting towards the storage limit. Downloaded photos that are no longer on disk are fetched again when you put them back up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .blocked:
            Text("These are never picked again, from any source, and their downloaded copies have been deleted. Photos in your own folders are only skipped — the files are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Account

private struct AccountSettings: View {
    @Bindable var manager: WallpaperManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                unsplash
                Divider()
                nasa
                Divider()
                wallhaven
            }
            .padding(20)
        }
    }

    // MARK: - Unsplash

    @State private var unsplashKey = ""
    @State private var isEditingUnsplash = false

    @ViewBuilder
    private var unsplash: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unsplash")
                .font(.headline)
            Text("Needed for topic, collection and search sources.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if manager.settings.hasAccessKey, !isEditingUnsplash, let existing = manager.settings.accessKey {
                storedKey(existing) {
                    unsplashKey = ""
                    isEditingUnsplash = true
                } remove: {
                    manager.settings.clearAccessKey()
                    unsplashKey = ""
                }
            } else {
                AccessKeyField(settings: manager.settings, key: $unsplashKey) {
                    isEditingUnsplash = false
                }
            }

            ApplicationNameField(settings: manager.settings)

            RateLimitGauge(name: "Unsplash", rateLimit: manager.client.rateLimit)

            DisclosureGroup("How to get a key") {
                AccessKeyGuide()
                    .padding(.top, 8)
            }
            .font(.callout.weight(.medium))
        }
    }

    // MARK: - NASA

    @State private var nasaKey = ""
    @State private var isEditingNASA = false

    @ViewBuilder
    private var nasa: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NASA")
                .font(.headline)
            Text("Needed for the Astronomy Picture of the Day source. Not needed for anything else.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if manager.settings.hasNASAKey, !isEditingNASA, let existing = manager.settings.nasaKey {
                storedKey(existing) {
                    nasaKey = ""
                    isEditingNASA = true
                } remove: {
                    manager.settings.clearNASAKey()
                    nasaKey = ""
                }
            } else {
                NASAKeyField(settings: manager.settings, key: $nasaKey) {
                    isEditingNASA = false
                }
            }

            RateLimitGauge(name: "NASA", rateLimit: manager.nasa.rateLimit)

            DisclosureGroup("How to get a key") {
                NASAKeyGuide()
                    .padding(.top, 8)
            }
            .font(.callout.weight(.medium))
        }
    }

    // MARK: - Wallhaven

    /// Here only to answer the question the other two sections raise. Wallhaven
    /// serves the safe-for-work wallpapers this app asks for to anonymous
    /// callers, so there is no key to store and none is ever sent.
    private var wallhaven: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wallhaven")
                .font(.headline)
            Label("No key needed.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
            Text("Wallhaven sources work straight away. The app asks only for safe-for-work wallpapers, and never sends an API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A key already in the keychain, shown masked — the value itself is never
    /// put on screen in full.
    private func storedKey(
        _ value: String,
        replace: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(Keychain.masked(value))
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Replace…", action: replace)
            Button("Remove", action: remove)
        }
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    @Bindable var manager: WallpaperManager
    @State private var isConfirmingClear = false

    private var limit: StorageLimit { manager.settings.settings.storageLimit }

    var body: some View {
        Form {
            Section {
                LabeledContent("Cached photos") {
                    Text("\(manager.cache.stats.count) photos · \(manager.cache.stats.formattedBytes)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(manager.cache.folder)
                    }
                    Button("Delete photos…") { isConfirmingClear = true }
                        .disabled(manager.cache.stats.count == 0)
                }
            } footer: {
                Text("Photos are kept in Application Support and named so you can find them on Unsplash again. The wallpapers currently on screen and the ones you pinned are never deleted.")
            }

            Section {
                Toggle("Limit how much is kept", isOn: Binding(
                    get: { limit.isEnabled },
                    set: { new in manager.settings.update { $0.storageLimit.isEnabled = new } }
                ))

                if limit.isEnabled {
                    TextField("Maximum photos", value: Binding(
                        get: { limit.maxPhotos },
                        set: { new in manager.settings.update { $0.storageLimit.maxPhotos = max(1, new) } }
                    ), format: .number)

                    TextField("Maximum size (GB)", value: Binding(
                        get: { Double(limit.maxBytes) / 1_073_741_824 },
                        set: { new in
                            manager.settings.update {
                                $0.storageLimit.maxBytes = Int64(max(0.1, new) * 1_073_741_824)
                            }
                        }
                    ), format: .number.precision(.fractionLength(0...1)))
                }
            } footer: {
                Text(limit.isEnabled
                     ? "Whichever limit is reached first removes the oldest photos."
                     : "Photos are kept until you delete them.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete \(manager.cache.stats.count) cached photos?",
            isPresented: $isConfirmingClear
        ) {
            Button("Delete", role: .destructive) { manager.clearCache() }
        } message: {
            Text("This frees \(manager.cache.stats.formattedBytes). The wallpapers currently on screen are kept, and so are the ones you pinned.")
        }
    }
}
