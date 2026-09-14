import SwiftUI

enum OnboardingWindow {
    static let id = "onboarding"
}

/// First-run setup: Access Key, then sources, then how often to change.
struct OnboardingView: View {
    @Bindable var manager: WallpaperManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .key
    @State private var key = ""

    enum Step: Int, CaseIterable {
        case key, sources, schedule

        var title: String {
            switch self {
            case .key: "Connect to Unsplash"
            case .sources: "Choose where photos come from"
            case .schedule: "Choose how often it changes"
            }
        }

        /// The key step can be passed straight through: a setup built only from
        /// folders on this Mac needs no key at all.
        var isOptional: Bool { self == .key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            // The key step is taller than the window; scroll the step content
            // so the header and the Continue button are never pushed off.
            ScrollView {
                Group {
                    switch step {
                    case .key: keyStep
                    case .sources:
                        SourceEditor(
                            settings: manager.settings,
                            client: manager.client,
                            wallhaven: manager.wallhaven
                        )
                    case .schedule: scheduleStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 480, height: 540)
        .onAppear { key = manager.settings.accessKey ?? "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.title)
                .font(.title2.weight(.semibold))
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)\(step.isOptional ? " · optional" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wallpaper uses your own Unsplash key, stored in your Mac's keychain. It never leaves this Mac except to talk to Unsplash.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Only needed for Unsplash sources. Skip it if you want Wallhaven, which needs no key, or folders of your own photos, which need no key and no connection.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            AccessKeyField(settings: manager.settings, key: $key) {}

            ApplicationNameField(settings: manager.settings)

            Divider()

            Text("Don't have a key yet?")
                .font(.callout.weight(.medium))
            AccessKeyGuide()
        }
    }

    private var scheduleStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            IntervalPicker(settings: manager.settings)

            MonitorModePicker(settings: manager.settings)
        }
    }

    private var footer: some View {
        HStack {
            if step != .key {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .key
                }
            }

            if let blockerMessage {
                Text(blockerMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(continueTitle) {
                advance()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdvance)
        }
    }

    private var continueTitle: String {
        if step == .schedule { return "Start" }
        // Nothing typed on an optional step: say so, rather than leaving the
        // user wondering whether they have missed something.
        if step == .key, !manager.settings.hasAccessKey { return "Skip" }
        return "Continue"
    }

    private var canAdvance: Bool {
        switch step {
        // Optional: a folder-only setup needs no key.
        case .key: true
        // Sources that are all waiting on a key would start an app that cannot
        // fetch anything, so the usable ones are what count.
        case .sources: !manager.settings.usableSources.isEmpty
        case .schedule: true
        }
    }

    /// Spelled out only when the reason is not already on screen. An empty list
    /// says "No sources yet" itself; a list whose sources all need a key does
    /// not explain itself at all.
    private var blockerMessage: String? {
        guard step == .sources,
              !manager.settings.settings.sources.isEmpty,
              manager.settings.usableSources.isEmpty
        else { return nil }

        return SetupError
            .noUsableSources(manager.settings.settings.sources)
            .localizedDescription
    }

    private func advance() {
        guard step == .schedule else {
            step = Step(rawValue: step.rawValue + 1) ?? .schedule
            return
        }

        manager.settings.update { $0.hasCompletedOnboarding = true }
        Task { await manager.completeSetup() }
        dismiss()
    }
}

/// Interval ladder, shared by setup and Settings.
struct IntervalPicker: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Change every", selection: Binding(
                get: { settings.settings.interval },
                set: { new in settings.update { $0.interval = new } }
            )) {
                ForEach(ChangeInterval.presets, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }

            // The worst case across the sources actually added: a change draws
            // one source at random, and folders cost nothing at all.
            let requests = settings.settings.interval
                .estimatedRequestsPerHour(costPerChange: costPerChange)
            if requests > 0 {
                Text("At most \(requests) API request\(requests == 1 ? "" : "s") per hour\(overDemoLimit(requests) ? " — above an Unsplash demo key's 50/hour limit." : ".")")
                    .font(.caption)
                    .foregroundStyle(overDemoLimit(requests) ? .orange : .secondary)
            }
        }
    }

    private var photosPerChange: Int {
        settings.settings.monitorMode == .differentPerScreen
            ? max(1, WallpaperSetter.screenCount)
            : 1
    }

    private var costPerChange: Int {
        Set(settings.settings.sources.map(\.kind.provider))
            .map { $0.requestCost(photosPerChange: photosPerChange) }
            .max() ?? 0
    }

    /// Only Unsplash has a 50/hour demo tier worth warning about.
    private func overDemoLimit(_ requests: Int) -> Bool {
        requests > 50 && settings.settings.sources.contains { $0.kind.provider == .unsplash }
    }
}

/// Multi-monitor behaviour, shared by setup and Settings.
struct MonitorModePicker: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Multiple displays", selection: Binding(
                get: { settings.settings.monitorMode },
                set: { new in settings.update { $0.monitorMode = new } }
            )) {
                ForEach(MonitorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if WallpaperSetter.screenCount > 1,
               settings.settings.monitorMode == .differentPerScreen {
                Text("\(WallpaperSetter.screenCount) displays connected — each change downloads \(WallpaperSetter.screenCount) photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


/// The name the user registered their application under on Unsplash. It is sent
/// as `utm_source` on every attribution link, which the API guidelines require
/// to match the registered application.
struct ApplicationNameField: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Application name on Unsplash", text: Binding(
                get: { settings.settings.applicationName },
                set: { new in settings.update { $0.applicationName = new } }
            ))
            .textFieldStyle(.roundedBorder)

            Text("Whatever you named the application when you created the key. Unsplash expects it on the attribution links.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
