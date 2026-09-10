import AppKit
import Foundation
import Network
import OSLog

/// Coordinates everything: picks a source, fetches photos, applies them and
/// keeps the next one ready on disk.
@Observable
final class WallpaperManager {
    enum Status: Equatable {
        case idle
        case working
        case failed(String)
        /// Offline, waiting for the network rather than burning retries.
        case waitingForNetwork(String)

        var errorMessage: String? {
            switch self {
            case .failed(let message), .waitingForNetwork(let message): message
            case .idle, .working: nil
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var lastChangeDate: Date?

    /// Set when the wallpaper did change, but from the cache rather than from
    /// Unsplash. Not an error — the desktop kept moving — so it is shown apart
    /// from `status`.
    private(set) var notice: String?

    /// A photo and the local file it was applied from.
    struct Applied: Codable, Hashable {
        var photo: Photo
        var url: URL
    }

    /// What is on screen right now, in screen order.
    ///
    /// Persisted, for two reasons: a Space coming forward after a relaunch has
    /// to be re-dressed from these files, and the menu has to keep crediting
    /// the photographers whose work is still on screen.
    private(set) var current: [Applied] = [] {
        didSet { persistCurrent() }
    }

    /// Photos currently on screen — every one of them has to be credited.
    var currentPhotos: [Photo] { current.map(\.photo) }

    let settings: SettingsStore
    let client: UnsplashClient
    let cache: ImageCache
    let scheduler: Scheduler

    /// Photos already downloaded for the next change, so applying a wallpaper
    /// touches the disk rather than the network.
    private var prefetched: [(photo: Photo, url: URL)] = []
    private var prefetchTask: Task<Void, Never>?

    /// Guards against two changes overlapping — they would race on `current`
    /// and stack two fade overlays on top of each other.
    private var isChanging = false

    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var networkMonitor: NWPathMonitor?

    private var screenObserver: (any NSObjectProtocol)?
    private var screenChangeTask: Task<Void, Never>?

    private var spaceObserver: (any NSObjectProtocol)?
    private var spaceChangeTask: Task<Void, Never>?

    /// One instance for the whole app: the scenes and the app delegate all
    /// need to reach the same state.
    static let shared = WallpaperManager()

    init(
        settings: SettingsStore = SettingsStore(),
        client: UnsplashClient = UnsplashClient(),
        cache: ImageCache = ImageCache(),
        scheduler: Scheduler = Scheduler()
    ) {
        self.settings = settings
        self.client = client
        self.cache = cache
        self.scheduler = scheduler
        self.current = Self.restoreCurrent()
    }

    // MARK: - Persisted state

    private static let currentKey = "currentWallpapers"

    /// Drops entries whose file has since been deleted — re-applying a missing
    /// file would clear the desktop.
    private static func restoreCurrent() -> [Applied] {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let decoded = try? JSONDecoder().decode([Applied].self, from: data)
        else { return [] }

        return decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func persistCurrent() {
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: Self.currentKey)
    }

    var isReady: Bool {
        settings.hasAccessKey && !settings.settings.sources.isEmpty
    }

    // MARK: - Lifecycle

    /// Called once at launch, and again whenever the interval changes.
    func start() {
        scheduler.start(interval: settings.settings.interval) { [weak self] in
            await self?.changeWallpaper()
        }
        observeScreenChanges()
        observeSpaceChanges()
        Log.wallpaper.info("rotation started, restored \(self.current.count, privacy: .public) applied photo(s)")

        Task {
            await scheduler.fireIfOverdue()
            prefetchNext()
        }
    }

    func intervalChanged() {
        scheduler.stop()
        start()
    }

    /// Puts the app to sleep for good: no schedule, no retries, no observers,
    /// no prefetch. Used by the uninstaller — a Space switch arriving halfway
    /// through would re-apply a photo that has just been deleted.
    func stopEverything() {
        scheduler.stop()
        cancelRetry()

        prefetchTask?.cancel()
        prefetchTask = nil
        prefetched.removeAll()

        screenChangeTask?.cancel()
        spaceChangeTask?.cancel()

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }

        Log.wallpaper.info("rotation stopped")
    }

    /// Finishes setup: clears any schedule left from an earlier configuration,
    /// starts rotation and puts the first wallpaper up right away.
    ///
    /// The reset matters — without it `start()` sees a due date that has long
    /// passed, fires a change for it, and the first wallpaper lands twice.
    func completeSetup() async {
        scheduler.reset()
        start()
        await changeNow()
    }

    // MARK: - Changing

    /// Applies the next wallpaper. Used by both the scheduler and the "change
    /// now" menu item; a manual change also pushes the next automatic one out a
    /// full interval.
    func changeNow() async {
        cancelRetry()
        await scheduler.fireNow()
    }

    private func changeWallpaper() async {
        guard !isChanging else {
            Log.wallpaper.debug("change already in progress, ignoring")
            return
        }
        isChanging = true
        defer { isChanging = false }

        guard settings.hasAccessKey else {
            status = .failed(UnsplashError.missingAccessKey.localizedDescription)
            return
        }
        guard !settings.settings.sources.isEmpty else {
            status = .failed("No sources added yet. Add one in Settings.")
            return
        }

        status = .working

        do {
            let needed = neededPhotoCount
            let batch = try await takePhotos(count: needed)

            try await applyWithTransition(batch.map(\.url))

            current = batch.map { Applied(photo: $0.photo, url: $0.url) }
            Log.wallpaper.info("wallpaper changed: \(batch.count, privacy: .public) photo(s)")
            lastChangeDate = Date()
            status = .idle
            notice = nil
            consecutiveFailures = 0
            stopNetworkMonitor()

            // Required by the Unsplash guidelines, but never worth failing over.
            for entry in batch {
                await client.reportDownload(for: entry.photo)
            }

            housekeep()
            prefetchNext()
        } catch {
            await handleFailure(error)
        }
    }

    /// Uses the prefetched photos when they fit, otherwise fetches fresh ones.
    private func takePhotos(count: Int) async throws -> [(photo: Photo, url: URL)] {
        if prefetched.count >= count {
            let batch = Array(prefetched.prefix(count))
            prefetched.removeFirst(count)
            return batch
        }

        prefetched.removeAll()
        return try await fetchAndDownload(count: count)
    }

    private func fetchAndDownload(count: Int) async throws -> [(photo: Photo, url: URL)] {
        guard let source = settings.settings.sources.randomElement() else {
            throw UnsplashError.missingAccessKey
        }

        let photos = try await client.randomPhotos(count: count, from: source)

        var results: [(photo: Photo, url: URL)] = []
        for (index, photo) in photos.prefix(count).enumerated() {
            let size = downloadSize(forScreenAt: index)
            results.append((photo, try await cache.download(photo, pixelSize: size)))
        }

        return results
    }

    /// `nil` means "leave the photo at its own size".
    private func downloadSize(forScreenAt index: Int) -> CGSize? {
        guard settings.settings.photoResolution != .original else { return nil }

        let sizes = WallpaperSetter.screenPixelSizes()

        // Per-screen mode already knows exactly which screen this photo is for.
        if settings.settings.monitorMode == .differentPerScreen, index < sizes.count {
            return sizes[index]
        }

        switch settings.settings.photoResolution {
        case .coverAllScreens:
            return WallpaperSetter.coveringPixelSize()
        case .largestScreen, .original:
            return WallpaperSetter.largestScreenPixelSize()
        }
    }

    // MARK: - Failure recovery

    /// What to do about a failed change. Some failures fix themselves, some
    /// need the user, and waiting a whole interval to find out which is no good
    /// when the interval is a week.
    private enum Recovery {
        case retry(after: TimeInterval)
        case waitForNetwork
        case userMustAct

        /// Only worth reaching for the cache when Unsplash is unreachable, not
        /// when the key or the sources are wrong.
        var allowsCacheFallback: Bool {
            switch self {
            case .retry, .waitForNetwork: true
            case .userMustAct: false
            }
        }
    }

    private func handleFailure(_ error: any Error) async {
        consecutiveFailures += 1
        let recovery = recovery(for: error)

        // Unsplash is out of reach, but the disk is not: keep rotating through
        // photos already downloaded rather than freezing on one wallpaper.
        let usedCache = recovery.allowsCacheFallback ? await applyFromCache() : false

        switch recovery {
        case .userMustAct:
            status = .failed(error.localizedDescription)
            notice = nil

        case .waitForNetwork:
            status = usedCache ? .idle : .waitingForNetwork("Offline — will retry when the network is back.")
            notice = usedCache ? "Offline — showing a photo you already have." : nil
            startNetworkMonitor()

        case .retry(let delay):
            status = usedCache ? .idle : .failed(error.localizedDescription)
            notice = usedCache ? cacheNotice(for: error) : nil
            scheduleRetry(after: delay)
        }
    }

    private func cacheNotice(for error: any Error) -> String {
        guard case .rateLimited(let resetsAt) = error as? UnsplashError else {
            return "Couldn't reach Unsplash — showing a photo you already have."
        }

        guard let resetsAt else {
            return "Unsplash hourly limit reached — showing a photo you already have."
        }
        let time = resetsAt.formatted(date: .omitted, time: .shortened)
        return "Unsplash hourly limit reached — showing a photo you already have. New ones at \(time)."
    }

    /// Picks photos already on disk, avoiding the ones on screen so the
    /// wallpaper visibly changes. Returns false when there is nothing to fall
    /// back to, which leaves the current wallpaper alone.
    private func applyFromCache() async -> Bool {
        let inUse = Set(current.map(\.url.standardizedFileURL))
        let candidates = cache.entries().filter { !inUse.contains($0.url.standardizedFileURL) }
        guard !candidates.isEmpty else {
            Log.wallpaper.debug("no cached photo to fall back to")
            return false
        }

        var chosen = Array(candidates.shuffled().prefix(neededPhotoCount))
        // Fewer cached photos than screens: repeat rather than give up.
        while chosen.count < neededPhotoCount, let first = chosen.first {
            chosen.append(first)
        }

        do {
            try await applyWithTransition(chosen.map(\.url))
        } catch {
            Log.wallpaper.error("cache fallback failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        current = chosen.map { Applied(photo: $0.photo, url: $0.url) }
        lastChangeDate = Date()
        // No download is reported: nothing was downloaded, and the photo was
        // already reported the first time it was used.
        Log.wallpaper.info("fell back to \(chosen.count, privacy: .public) cached photo(s)")
        return true
    }

    private func recovery(for error: any Error) -> Recovery {
        guard let unsplashError = error as? UnsplashError else {
            return .retry(after: backoffDelay)
        }

        switch unsplashError {
        case .missingAccessKey, .invalidAccessKey, .noPhotosFound:
            // Nothing retrying can fix — the key or the source has to change.
            return .userMustAct

        case .rateLimited(let resetsAt):
            // Retrying before the quota rolls over just wastes requests.
            let wait = (resetsAt?.timeIntervalSinceNow ?? 3600) + 60
            return .retry(after: max(60, wait))

        case .unexpectedStatus:
            return .retry(after: backoffDelay)

        case .transport(let underlying):
            let code = (underlying as NSError).code
            let offline = [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
            ]
            return offline.contains(code) ? .waitForNetwork : .retry(after: backoffDelay)
        }
    }

    /// 30s, 1m, 2m, 5m, 15m, then flat. Long enough not to hammer Unsplash,
    /// short enough that a week-long interval isn't stuck for a week.
    private var backoffDelay: TimeInterval {
        let ladder: [TimeInterval] = [30, 60, 120, 300, 900]
        return ladder[min(consecutiveFailures - 1, ladder.count - 1)]
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.changeWallpaper()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        consecutiveFailures = 0
        notice = nil
        stopNetworkMonitor()
    }

    /// Runs only while offline. An idle app has no monitor and no timer.
    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, networkMonitor != nil else { return }
                stopNetworkMonitor()
                await changeWallpaper()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        networkMonitor = monitor
    }

    private func stopNetworkMonitor() {
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    // MARK: - Displays

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WallpaperManager.shared.screenConfigurationChanged()
            }
        }
    }

    /// Plugging in a display leaves it with whatever macOS picked, and
    /// unplugging one shifts the rest along. Debounced, because the
    /// notification arrives several times per change.
    private func screenConfigurationChanged() {
        Log.wallpaper.debug("screen configuration changed")
        screenChangeTask?.cancel()
        screenChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.redressScreens()
        }
    }

    private func redressScreens() async {
        guard !current.isEmpty else { return }

        let screens = WallpaperSetter.screenCount

        if settings.settings.monitorMode == .differentPerScreen, screens > current.count {
            // A new display needs a photo of its own.
            await changeWallpaper()
            return
        }

        if settings.settings.monitorMode == .differentPerScreen {
            // Fewer displays than photos: reuse what we already have on disk.
            current = Array(current.prefix(max(1, screens)))
        }
        applyCurrent()
    }

    /// Applies a new set of photos, cross-fading if the user wants that.
    private func applyWithTransition(_ urls: [URL]) async throws {
        let sameForAll = settings.settings.monitorMode == .sameOnAllScreens || urls.count == 1

        let apply = {
            if sameForAll {
                try WallpaperSetter.apply(urls[0])
            } else {
                try WallpaperSetter.apply(perScreen: urls)
            }
        }

        guard settings.settings.fadeTransition else {
            try apply()
            return
        }

        let pairs = NSScreen.screens.enumerated().map { index, screen in
            (screen: screen, url: sameForAll ? urls[0] : urls[min(index, urls.count - 1)])
        }
        try await WallpaperFade.run(pairs, apply: apply)
    }

    /// Re-applies the photos we already have. Costs nothing but a call into the
    /// wallpaper agent — the files are already on disk.
    ///
    /// Deliberately never fades: this runs on every Space switch, and fading
    /// there would animate the desktop each time the user changes desktop.
    private func applyCurrent() {
        guard !current.isEmpty else {
            Log.wallpaper.debug("re-apply skipped: nothing applied yet")
            return
        }

        do {
            if settings.settings.monitorMode == .sameOnAllScreens || current.count == 1 {
                try WallpaperSetter.apply(current[0].url)
            } else {
                try WallpaperSetter.apply(perScreen: current.map(\.url))
            }
            Log.wallpaper.debug(
                "re-applied \(self.current.count, privacy: .public) photo(s) to \(WallpaperSetter.screenCount, privacy: .public) screen(s)"
            )
        } catch {
            Log.wallpaper.error("re-apply failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Spaces

    /// macOS stores the wallpaper per *display and Space*, and
    /// `setDesktopImageURL` only ever writes to the Space that display is
    /// currently showing. A display sitting on another Space therefore keeps
    /// the old photo until that Space comes forward — there is no public API to
    /// enumerate Spaces. So re-apply whenever the active Space changes.
    private func observeSpaceChanges() {
        guard spaceObserver == nil else { return }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WallpaperManager.shared.activeSpaceChanged()
            }
        }
    }

    private func activeSpaceChanged() {
        Log.wallpaper.debug("active Space changed")

        // Immediately, so a Space that has not been dressed yet shows the right
        // photo as soon as possible...
        applyCurrent()

        // ...and again once the switch has settled, since a write during the
        // transition can be dropped.
        spaceChangeTask?.cancel()
        spaceChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.applyCurrent()
        }
    }

    // MARK: - Prefetch

    private func prefetchNext() {
        guard isReady, prefetchTask == nil else { return }

        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer { prefetchTask = nil }

            let needed = neededPhotoCount
            guard prefetched.count < needed else { return }

            // A failed prefetch is not worth surfacing — the next change will
            // fetch fresh photos and report the error then.
            if let batch = try? await fetchAndDownload(count: needed) {
                prefetched = batch
                housekeep()
            }
        }
    }

    // MARK: - Storage

    private var neededPhotoCount: Int {
        settings.settings.monitorMode == .differentPerScreen
            ? max(1, WallpaperSetter.screenCount)
            : 1
    }

    /// Files that must survive eviction: what is on screen now, and what is
    /// queued for the next change.
    private var pinnedURLs: Set<URL> {
        WallpaperSetter.currentWallpaperURLs()
            .union(prefetched.map(\.url))
            .union(current.map(\.url))
    }

    private func housekeep() {
        cache.enforce(settings.settings.storageLimit, pinned: pinnedURLs)
    }

    /// "Delete photos" in Settings. Keeps the current wallpapers so the desktop
    /// survives, and drops the prefetch queue along with the files.
    func clearCache() {
        prefetched.removeAll()
        cache.clear(keeping: pinnedURLs)
    }
}
