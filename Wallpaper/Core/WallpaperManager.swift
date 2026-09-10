import AppKit
import Foundation
import Network

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

    /// What is on screen right now, in screen order. Kept with the local file
    /// so a display can be re-dressed without going back to the network.
    private(set) var current: [(photo: Photo, url: URL)] = []

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

    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var networkMonitor: NWPathMonitor?

    private var screenObserver: (any NSObjectProtocol)?
    private var screenChangeTask: Task<Void, Never>?

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

        Task {
            await scheduler.fireIfOverdue()
            prefetchNext()
        }
    }

    func intervalChanged() {
        scheduler.stop()
        start()
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

            if settings.settings.monitorMode == .sameOnAllScreens || batch.count == 1 {
                try WallpaperSetter.apply(batch[0].url)
            } else {
                try WallpaperSetter.apply(perScreen: batch.map(\.url))
            }

            current = batch
            lastChangeDate = Date()
            status = .idle
            consecutiveFailures = 0
            stopNetworkMonitor()

            // Required by the Unsplash guidelines, but never worth failing over.
            for entry in batch {
                await client.reportDownload(for: entry.photo)
            }

            housekeep()
            prefetchNext()
        } catch {
            handleFailure(error)
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
        let sizes = WallpaperSetter.screenPixelSizes()
        let largest = sizes.max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 2560, height: 1440)

        var results: [(photo: Photo, url: URL)] = []
        for (index, photo) in photos.prefix(count).enumerated() {
            // Per-screen mode sizes each download for its own screen.
            let size = settings.settings.monitorMode == .differentPerScreen && index < sizes.count
                ? sizes[index]
                : largest
            results.append((photo, try await cache.download(photo, pixelSize: size)))
        }

        return results
    }

    // MARK: - Failure recovery

    /// What to do about a failed change. Some failures fix themselves, some
    /// need the user, and waiting a whole interval to find out which is no good
    /// when the interval is a week.
    private enum Recovery {
        case retry(after: TimeInterval)
        case waitForNetwork
        case userMustAct
    }

    private func handleFailure(_ error: any Error) {
        consecutiveFailures += 1

        switch recovery(for: error) {
        case .userMustAct:
            status = .failed(error.localizedDescription)

        case .waitForNetwork:
            status = .waitingForNetwork("Offline — will retry when the network is back.")
            startNetworkMonitor()

        case .retry(let delay):
            status = .failed(error.localizedDescription)
            scheduleRetry(after: delay)
        }
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

        if settings.settings.monitorMode == .sameOnAllScreens {
            try? WallpaperSetter.apply(current[0].url)
            return
        }

        if screens <= current.count {
            // Fewer displays than photos: reuse what we already have on disk.
            current = Array(current.prefix(max(1, screens)))
            try? WallpaperSetter.apply(perScreen: current.map(\.url))
        } else {
            // A new display needs a photo of its own.
            await changeWallpaper()
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
