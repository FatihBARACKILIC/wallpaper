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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            Group {
                switch step {
                case .key: keyStep
                case .sources: SourceEditor(settings: manager.settings)
                case .schedule: scheduleStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 460, height: 480)
        .onAppear { key = manager.settings.accessKey ?? "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.title)
                .font(.title2.weight(.semibold))
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wallpaper uses your own Unsplash key, stored in your Mac's keychain. It never leaves this Mac except to talk to Unsplash.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            AccessKeyField(key: $key) {}

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

            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if step != .key {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .key
                }
            }

            Spacer()

            Button(step == .schedule ? "Start" : "Continue") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdvance)
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .key: manager.settings.hasAccessKey
        case .sources: !manager.settings.settings.sources.isEmpty
        case .schedule: true
        }
    }

    private func advance() {
        guard step == .schedule else {
            step = Step(rawValue: step.rawValue + 1) ?? .schedule
            return
        }

        manager.settings.update { $0.hasCompletedOnboarding = true }
        manager.start()
        Task { await manager.changeNow() }
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

            let requests = settings.settings.interval
                .estimatedRequestsPerHour(screenCount: photosPerChange)
            if requests > 0 {
                Text("About \(requests) Unsplash requests per hour\(requests > 50 ? " — above a demo key's 50/hour limit." : ".")")
                    .font(.caption)
                    .foregroundStyle(requests > 50 ? .orange : .secondary)
            }
        }
    }

    private var photosPerChange: Int {
        settings.settings.monitorMode == .differentPerScreen
            ? max(1, WallpaperSetter.screenCount)
            : 1
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
