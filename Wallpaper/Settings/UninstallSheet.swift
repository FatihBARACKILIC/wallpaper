import SwiftUI

/// The confirmation for "Uninstall Wallpaper".
///
/// It lists what is about to go, item by item, rather than asking "are you
/// sure": the whole point of the button is that the user does not have to trust
/// the app about what it left lying around.
struct UninstallSheet: View {
    @Bindable var manager: WallpaperManager

    @Environment(\.dismiss) private var dismiss

    @State private var trashApp = true
    @State private var report: Uninstaller.Report?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let report {
                failure(report)
            } else {
                confirmation
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Confirmation

    private var confirmation: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text("Uninstall Wallpaper")
                    .font(.title3.weight(.semibold))
                Text("Everything Wallpaper has stored on this Mac is removed. This can't be undone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                if manager.cache.stats.count > 0 {
                    item(
                        "photo.stack",
                        "Downloaded photos",
                        "\(manager.cache.stats.count) photos · \(manager.cache.stats.formattedBytes)"
                    )
                }
                item("gearshape", "Settings, sources and schedule", "Preferences and caches")
                if manager.settings.hasAccessKey {
                    item("key", "Your Unsplash Access Key", "Login keychain")
                }
                if LoginItem.isEnabled {
                    item("power", "Open at login", "Registration is removed")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))

            Toggle("Move Wallpaper.app to the Trash", isOn: $trashApp)

            Text("Your desktop returns to the macOS default wallpaper. Spaces you aren't looking at keep the old photo until you pick one yourself in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { uninstall() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: - Failure

    /// Only ever shown when something survived: a clean uninstall quits the app
    /// instead of returning here.
    private func failure(_ report: Uninstaller.Report) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Label("Some things couldn't be removed", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Everything else is gone. Remove these by hand and Wallpaper is off this Mac for good.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.failedFiles, id: \.self) { url in
                    HStack {
                        Text(url.path(percentEncoded: false))
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Show") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.link)
                    }
                }
                if report.keychainFailed {
                    Text("The Access Key is still in your login keychain — remove it with Keychain Access.")
                        .font(.caption)
                }
                if report.loginItemFailed {
                    Text("Wallpaper is still registered to open at login — remove it in System Settings › General › Login Items.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let appTrashError = report.appTrashError {
                    Text("The app itself couldn't be moved to the Trash: \(appTrashError)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Quit Wallpaper") { Uninstaller.quit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Running

    private func uninstall() {
        let result = Uninstaller.run(manager: manager, trashingApp: trashApp)

        guard result.isClean else {
            report = result
            return
        }
        Uninstaller.quit()
    }
}
