import SwiftUI

@main
struct WallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var manager = WallpaperManager.shared

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
                .task { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(
            manager.settings.settings.hasCompletedOnboarding ? .suppressed : .presented
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: WallpaperManager { .shared }

    /// The unit tests are hosted inside this app, so running them launches it.
    /// Without this the test run would change the developer's own wallpaper.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        // Setup starts rotation itself once it completes; starting here too
        // would fetch photos before there is a key to fetch them with.
        guard manager.settings.settings.hasCompletedOnboarding else { return }
        manager.start()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A change due while the Mac was asleep should happen on wake, not be
        // skipped until the next full interval.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await WallpaperManager.shared.scheduler.fireIfOverdue()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
