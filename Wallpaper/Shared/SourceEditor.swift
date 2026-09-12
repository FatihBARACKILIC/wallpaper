import AppKit
import SwiftUI

/// Add/remove list of photo sources, shared by setup and Settings.
struct SourceEditor: View {
    @Bindable var settings: SettingsStore
    let client: UnsplashClient

    @State private var input = ""
    @State private var resolveError: String?

    /// How many images each folder holds, keyed by source.
    ///
    /// Counted once off the main thread rather than in the row body: scanning
    /// is a full recursive walk of the folder, and a body runs again on every
    /// keystroke in the text field above.
    @State private var folderCounts: [UUID: Int?] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Topic, search term, or a pasted Unsplash link", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)

                Button("Add", action: add)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let preview = Source(input: input) {
                Text("Will be added as — \(preview.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    chooseFolders()
                } label: {
                    Label("Add folders…", systemImage: "folder.badge.plus")
                }
                .help("Use your own photos. Nothing is uploaded, and the files are never moved or changed.")

                Button {
                    add(Source.apod)
                } label: {
                    Label("Add NASA APOD", systemImage: "sparkles")
                }
                .disabled(settings.settings.sources.contains { $0.kind == .apod })
                .help("NASA's Astronomy Picture of the Day")

                Spacer()
            }

            List {
                ForEach(settings.settings.sources) { source in
                    row(for: source)
                }
            }
            .frame(minHeight: 120)
            .overlay {
                if settings.settings.sources.isEmpty {
                    Text("No sources yet. Add at least one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let resolveError {
                Text(resolveError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Each wallpaper change picks one of these at random. t/ is a topic, c/ a collection, s/ a search, f/ a folder on this Mac, n/ NASA.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await resolveMissingTitles() }
        .task(id: folderSignature) { await countFolders() }
    }

    /// Changes when a folder is added or removed, so the counts are recomputed
    /// then and not on every redraw.
    private var folderSignature: [String] {
        settings.settings.sources.filter { $0.kind == .folder }.map(\.value)
    }

    private func countFolders() async {
        let folders = settings.settings.sources.filter { $0.kind == .folder }
        for source in folders {
            let url = source.folderURL
            let count = await Task.detached(priority: .utility) {
                LocalFolder.imageCount(in: url)
            }.value
            folderCounts[source.id] = count
        }
    }

    private func row(for source: Source) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: source.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(source.shortLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let note = note(for: source) {
                    Text(note.text)
                        .font(.caption2)
                        .foregroundStyle(note.isProblem ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if source.needsTitle {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if let url = source.webURL {
                Button {
                    if source.kind == .folder {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: source.kind == .folder ? "folder" : "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help(source.kind == .folder ? "Show in Finder" : "Open in your browser")
            }

            Button {
                remove(source)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
    }

    /// The second line on a row: how many photos a folder holds, or what is
    /// stopping this source from being used.
    private func note(for source: Source) -> (text: String, isProblem: Bool)? {
        guard settings.canUse(source) else {
            return switch source.kind.provider {
            case .apod: ("Needs a NASA API key", true)
            default: ("Needs an Unsplash Access Key", true)
            }
        }

        guard source.kind == .folder else { return nil }

        // Still being counted.
        guard let count = folderCounts[source.id] else { return nil }

        guard let count else {
            return ("Folder unavailable — moved, renamed, or on a drive that isn't plugged in", true)
        }
        return ("\(count) photo\(count == 1 ? "" : "s")", false)
    }

    private func icon(for kind: Source.Kind) -> String {
        switch kind {
        case .topic: "square.grid.2x2"
        case .collection: "rectangle.stack"
        case .search: "magnifyingglass"
        case .apod: "sparkles"
        case .folder: "folder"
        }
    }

    // MARK: - Adding

    private func add() {
        guard let source = Source(input: input) else { return }
        add(source)
        input = ""
    }

    private func add(_ source: Source) {
        // Adding the same thing twice would just skew the random pick.
        guard !settings.settings.sources.contains(where: {
            $0.kind == source.kind && $0.value.caseInsensitiveCompare(source.value) == .orderedSame
        }) else { return }

        settings.update { $0.sources.append(source) }
        Task { await resolveMissingTitles() }
    }

    /// Several folders can be picked at once, and more added later — every one
    /// of them joins the same random rotation.
    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders of photos to use as wallpaper."

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            add(.folder(at: url))
        }
    }

    private func remove(_ source: Source) {
        settings.update { $0.sources.removeAll { $0.id == source.id } }
    }

    /// Turns collection IDs into their names. Runs once per collection; the
    /// title is stored with the source.
    private func resolveMissingTitles() async {
        for source in settings.settings.sources where source.needsTitle {
            do {
                let title = try await client.collectionTitle(for: source.value)
                settings.update { settings in
                    guard let index = settings.sources.firstIndex(where: { $0.id == source.id })
                    else { return }
                    settings.sources[index].title = title
                }
                resolveError = nil
            } catch {
                resolveError = "Couldn't look up collection \(source.value): \(error.localizedDescription)"
            }
        }
    }
}
