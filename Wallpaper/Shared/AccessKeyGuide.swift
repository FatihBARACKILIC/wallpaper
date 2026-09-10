import SwiftUI

/// In-app instructions for obtaining an Unsplash Access Key. Kept in the app
/// rather than linked out so it still works offline and cannot rot with a
/// changed help URL.
struct AccessKeyGuide: View {
    private static let applicationsURL = URL(string: "https://unsplash.com/oauth/applications")!

    private static let steps = [
        "Sign in at unsplash.com, or create a free account.",
        "Open the developer applications page and click New Application.",
        "Accept the API terms and give the application any name.",
        "Copy the Access Key — the Secret Key is not needed.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(step)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Link(destination: Self.applicationsURL) {
                Label("Open the Unsplash applications page", systemImage: "arrow.up.forward.square")
            }
            .font(.callout)

            Text("New applications start in Demo mode with 50 requests per hour. A wallpaper change costs about 2, so that is plenty.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Text field plus "verify against the API" button, shared by setup and
/// Settings. Verification makes one real request so a wrong key is caught here
/// rather than silently at the next wallpaper change.
struct AccessKeyField: View {
    @Bindable var settings: SettingsStore
    @Binding var key: String
    var onVerified: () -> Void

    @State private var verification: Verification = .idle

    enum Verification: Equatable {
        case idle
        case checking
        case valid
        case invalid(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField("Access Key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { verification = .idle }

                Button("Verify") { verify() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || verification == .checking)
            }

            switch verification {
            case .idle:
                EmptyView()
            case .checking:
                Label("Checking…", systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .valid:
                Label("Key works", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .invalid(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func verify() {
        let candidate = key.trimmingCharacters(in: .whitespaces)
        verification = .checking

        Task {
            let client = UnsplashClient(accessKeyProvider: { candidate })
            do {
                _ = try await client.randomPhotos(count: 1, from: Source(kind: .search, value: "nature"))
                // Through the store, never straight to the keychain: it is what
                // tells the rest of the UI a key now exists.
                try settings.setAccessKey(candidate)
                verification = .valid
                onVerified()
            } catch {
                verification = .invalid(error.localizedDescription)
            }
        }
    }
}
