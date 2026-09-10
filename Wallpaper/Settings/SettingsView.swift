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

    var body: some View {
        Form {
            Section {
                IntervalPicker(settings: manager.settings)
                MonitorModePicker(settings: manager.settings)

                Toggle("Fade between wallpapers", isOn: Binding(
                    get: { manager.settings.settings.fadeTransition },
                    set: { new in manager.settings.update { $0.fadeTransition = new } }
                ))
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
        }
        .formStyle(.grouped)
        .onChange(of: manager.settings.settings.interval) { manager.intervalChanged() }
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
    @State private var key = ""
    @State private var isEditing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let existing = manager.settings.accessKey, !isEditing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Access Key")
                            .font(.callout.weight(.medium))
                        HStack {
                            Text(Keychain.masked(existing))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Replace…") {
                                key = ""
                                isEditing = true
                            }
                            Button("Remove") {
                                manager.settings.clearAccessKey()
                                key = ""
                            }
                        }
                    }
                } else {
                    AccessKeyField(key: $key) { isEditing = false }
                }

                ApplicationNameField(settings: manager.settings)

                RateLimitGauge(rateLimit: manager.client.rateLimit)

                Divider()

                Text("How to get a key")
                    .font(.callout.weight(.medium))
                AccessKeyGuide()
            }
            .padding(20)
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
