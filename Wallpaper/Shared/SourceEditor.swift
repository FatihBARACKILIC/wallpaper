import SwiftUI

/// Add/remove list of photo sources, shared by setup and Settings.
struct SourceEditor: View {
    @Bindable var settings: SettingsStore

    @State private var input = ""
    @State private var selection: Source.ID?

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

            List(selection: $selection) {
                ForEach(settings.settings.sources) { source in
                    HStack {
                        Image(systemName: icon(for: source.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(source.value)
                        Spacer()
                        Text(source.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button {
                            remove(source)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .tag(source.id)
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

            Text("Each wallpaper change picks one of these at random.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    }

    private func remove(_ source: Source) {
        settings.update { $0.sources.removeAll { $0.id == source.id } }
    }
}
