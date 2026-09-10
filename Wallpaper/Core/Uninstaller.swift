import AppKit
import Foundation
import OSLog
import ServiceManagement

/// Removes everything the app has written outside its own bundle, so that
/// dragging Wallpaper.app to the Trash really is the end of it.
///
/// The app is deliberately unsandboxed, so its data is spread over four places
/// instead of one container: Application Support (the photos and the index),
/// the preferences plist, the URLSession caches, and the login keychain — plus
/// the login item registered with `SMAppService`. Anything new the app writes
/// has to be added to this list too, or the uninstaller quietly starts lying.
enum Uninstaller {
    /// What the uninstall could not get rid of. An empty result means the Mac
    /// is clean and the app can quit.
    struct Report {
        var failedFiles: [URL] = []
        var keychainFailed = false
        var loginItemFailed = false
        var appTrashError: String?

        var isClean: Bool {
            failedFiles.isEmpty && !keychainFailed && !loginItemFailed && appTrashError == nil
        }
    }

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.barackilic.Wallpaper"
    }

    /// The macOS stock wallpaper. The desktop has to point somewhere before the
    /// photos are deleted, or it is left showing a file that no longer exists.
    private static let defaultDesktopPicture = URL(
        fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic"
    )

    // MARK: - Inventory

    /// Everything on disk, in removal order. `photoFolder` is `ImageCache`'s
    /// folder — its parent is what actually gets removed, since the index sits
    /// beside the photos rather than inside them.
    ///
    /// Only paths that exist are returned: the confirmation shows this list, and
    /// promising to delete a file that was never created is noise.
    static func fileURLs(photoFolder: URL) -> [URL] {
        let library = Self.library

        return [
            photoFolder.deletingLastPathComponent(),
            preferencesURL,
            library.appending(path: "Caches/\(bundleID)", directoryHint: .isDirectory),
            library.appending(path: "HTTPStorages/\(bundleID)", directoryHint: .isDirectory),
            library.appending(path: "HTTPStorages/\(bundleID).binarycookies"),
            library.appending(path: "Saved Application State/\(bundleID).savedState", directoryHint: .isDirectory),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var library: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    /// Owned by cfprefsd rather than by this app — see `removeAfterExit`.
    private static var preferencesURL: URL {
        library.appending(path: "Preferences/\(bundleID).plist")
    }

    // MARK: - Running

    /// Stops the app doing any more work, then removes the lot.
    ///
    /// Order matters: rotation and the Space/display observers go first, so
    /// nothing re-applies a photo that is about to be deleted, and the desktop
    /// is handed back to the macOS default *before* the photos disappear.
    @MainActor
    static func run(manager: WallpaperManager, trashingApp: Bool) -> Report {
        var report = Report()

        manager.stopEverything()
        restoreDefaultWallpaper()

        // `unregister` throws when there was no registration to remove, so the
        // error proves nothing on its own: a Mac where "open at login" was never
        // switched on would be told to go and remove a login item that does not
        // exist. Only the status afterwards says whether anything is left.
        do {
            try LoginItem.setEnabled(false)
        } catch {
            Log.wallpaper.debug("uninstall: login item: \(error.localizedDescription, privacy: .public)")
        }
        report.loginItemFailed = LoginItem.isRegistered

        Keychain.delete()
        report.keychainFailed = Keychain.read() != nil

        // Empties the settings, the schedule and the topic-ID cache now, so
        // what cfprefsd flushes on exit is an empty domain rather than the
        // user's configuration. The file itself goes in `quit()`.
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: bundleID)
        defaults.synchronize()

        for url in fileURLs(photoFolder: manager.cache.folder) {
            // The preferences plist belongs to cfprefsd: deleting it from here
            // only has it written straight back. It goes after the app quits.
            guard url != preferencesURL else { continue }

            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                report.failedFiles.append(url)
                Log.wallpaper.error(
                    "uninstall: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // Nothing to move when the bundle is already gone — a second run, or an
        // app launched from a path that has since been deleted. That is the
        // desired end state, not a failure to report.
        let bundleURL = Bundle.main.bundleURL
        if trashingApp, FileManager.default.fileExists(atPath: bundleURL.path) {
            do {
                try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
            } catch {
                report.appTrashError = error.localizedDescription
                Log.wallpaper.error("uninstall: app bundle: \(error.localizedDescription, privacy: .public)")
            }
        }

        Log.wallpaper.info("uninstall finished, clean: \(report.isClean, privacy: .public)")
        return report
    }

    /// Ends the app, taking the preferences file with it. The only way out of
    /// an uninstall — the deferred delete is timed against this process, so it
    /// has to be scheduled as the app goes, not minutes earlier while the user
    /// is still reading a failure report.
    ///
    /// `exit` rather than `NSApp.terminate`, for two reasons. The polite call is
    /// swallowed when it comes from inside a sheet's own action: AppKit holds
    /// the quit until the modal session ends, and that session does not end
    /// until the action returns — leaving the app running with its own bundle
    /// already in the Trash. And an orderly shutdown writes window state back
    /// into the preferences domain that was just emptied. Neither matters here:
    /// everything this app owns has already been deleted, so there is nothing
    /// left worth saving on the way out.
    @MainActor
    static func quit() -> Never {
        removeAfterExit([preferencesURL])
        exit(EXIT_SUCCESS)
    }

    /// cfprefsd owns the preferences file, not this app: when the process ends
    /// it writes its in-memory copy back out, so an empty plist reappears
    /// however carefully the file was deleted first — emptying the domain
    /// beforehand is not enough either. Verified: a 42-byte stub every time.
    ///
    /// The last removal therefore has to outlive the process — and wait a beat
    /// after it, because cfprefsd flushes a moment *after* the app is gone: a
    /// delete racing it straight away loses. Paths travel as arguments rather
    /// than inside the script text, so a home folder with a space in it cannot
    /// reshape the command.
    private static func removeAfterExit(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            // Give up waiting after ~20s: an app that somehow never quits
            // should not leave a shell watching for it forever.
            """
            pid=$1; shift
            n=0
            while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.2; n=$((n+1)); done
            sleep 3
            rm -rf "$@"
            """,
            "sh",
            String(ProcessInfo.processInfo.processIdentifier),
        ] + urls.map(\.path)

        do {
            try task.run()
        } catch {
            Log.wallpaper.error("uninstall: deferred cleanup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Points the desktop back at the stock wallpaper.
    ///
    /// Same limit as everywhere else in this app: `setDesktopImageURL` reaches
    /// only the Space each display is showing right now. Spaces the user is not
    /// looking at keep pointing at a deleted file until they pick a wallpaper
    /// themselves — which is why the confirmation says so.
    private static func restoreDefaultWallpaper() {
        guard FileManager.default.fileExists(atPath: defaultDesktopPicture.path) else { return }
        try? WallpaperSetter.apply(defaultDesktopPicture)
    }
}
