import SwiftUI

@main
struct WallpaperApp: App {
    @State private var manager = WallpaperManager()

    var body: some Scene {
        MenuBarExtra("Wallpaper", systemImage: "photo.on.rectangle.angled") {
            MenuContent(manager: manager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(manager: manager)
        }

        Window("Set up Wallpaper", id: OnboardingWindow.id) {
            OnboardingView(manager: manager)
                .task { openOnboardingIfNeeded() }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(manager.settings.settings.hasCompletedOnboarding ? .suppressed : .presented)
    }

    private func openOnboardingIfNeeded() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
