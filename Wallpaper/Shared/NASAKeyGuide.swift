import SwiftUI

/// In-app instructions for obtaining a NASA API key. Kept in the app for the
/// same reason as `AccessKeyGuide`: it still works offline and cannot rot with
/// a changed help URL.
struct NASAKeyGuide: View {
    private static let signupURL = URL(string: "https://api.nasa.gov")!

    private static let steps = [
        "Open api.nasa.gov and fill in the short signup form.",
        "The key arrives by email straight away — no account to create.",
        "Paste it here.",
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

            Link(destination: Self.signupURL) {
                Label("Open api.nasa.gov", systemImage: "arrow.up.forward.square")
            }
            .font(.callout)

            Text("A personal key allows 1000 requests per hour. A wallpaper change costs one, because APOD returns every photo in a single request.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Text field plus "verify against the API" button for the NASA key, matching
/// `AccessKeyField`. Verification makes one real request so a wrong key is
/// caught here rather than silently at the next wallpaper change.
struct NASAKeyField: View {
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
                SecureField("NASA API key", text: $key)
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
            let client = NASAClient(apiKeyProvider: { candidate })
            do {
                try await client.validate(key: candidate)
                // Through the store, never straight to the keychain: it is what
                // tells the rest of the UI a key now exists.
                try settings.setNASAKey(candidate)
                verification = .valid
                onVerified()
            } catch {
                verification = .invalid(error.localizedDescription)
            }
        }
    }
}
