import SwiftUI

/// Add/remove list of photo sources, shared by setup and Settings.
struct SourceEditor: View {
    @Bindable var settings: SettingsStore
    let client: UnsplashClient

    @State private var input = ""
    @State private var resolveError: String?

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

            Text("Each wallpaper change picks one of these at random. t/ is a topic, c/ a collection, s/ a search.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await resolveMissingTitles() }
    }

    private func row(for source: Source) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: source.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(source.shortLabel)
                .lineLimit(1)
                .truncationMode(.middle)

            if source.needsTitle {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            if let url = source.webURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open on Unsplash")
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

    private func icon(for kind: Source.Kind) -> String {
        switch kind {
        case .topic: "square.grid.2x2"
        case .collection: "rectangle.stack"
        case .search: "magnifyingglass"
        }
    }

    private func add() {
        guard let source = Source(input: input) else { return }
        // Adding the same thing twice would just skew the random pick.
        guard !settings.settings.sources.contains(where: {
            $0.kind == source.kind && $0.value.caseInsensitiveCompare(source.value) == .orderedSame
        }) else {
            input = ""
            return
        }

        settings.update { $0.sources.append(source) }
        input = ""
        Task { await resolveMissingTitles() }
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
