import SwiftUI

struct SettingsView: View {
    @Bindable var manager: WallpaperManager

    var body: some View {
        TabView {
            GeneralSettings(manager: manager)
                .tabItem { Label("General", systemImage: "gearshape") }

            SourcesSettings(manager: manager)
                .tabItem { Label("Sources", systemImage: "photo.stack") }

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
            SourceEditor(settings: manager.settings, client: manager.client)
        }
        .padding(20)
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
                Text("Photos are kept in Application Support and named so you can find them on Unsplash again. The wallpapers currently on screen are never deleted.")
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
            Text("This frees \(manager.cache.stats.formattedBytes). The wallpapers currently on screen are kept.")
        }
    }
}
