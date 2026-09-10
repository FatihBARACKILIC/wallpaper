import AppKit
import Foundation

/// Coordinates everything: picks a source, fetches photos, applies them and
/// keeps the next one ready on disk.
@Observable
final class WallpaperManager {
    enum Status: Equatable {
        case idle
        case working
        case failed(String)

        var errorMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    private(set) var status: Status = .idle
    /// Photos currently on screen, in screen order.
    private(set) var currentPhotos: [Photo] = []
    private(set) var lastChangeDate: Date?

    let settings: SettingsStore
    let client: UnsplashClient
    let cache: ImageCache
    let scheduler: Scheduler

    /// Photos already downloaded for the next change, so applying a wallpaper
    /// touches the disk rather than the network.
    private var prefetched: [(photo: Photo, url: URL)] = []
    private var prefetchTask: Task<Void, Never>?

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

            currentPhotos = batch.map(\.photo)
            lastChangeDate = Date()
            status = .idle

            // Required by the Unsplash guidelines, but never worth failing over.
            for entry in batch {
                await client.reportDownload(for: entry.photo)
            }

            housekeep()
            prefetchNext()
        } catch {
            status = .failed(error.localizedDescription)
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
        WallpaperSetter.currentWallpaperURLs().union(prefetched.map(\.url))
    }

    private func housekeep() {
        cache.enforce(settings.settings.storageLimit, pinned: pinnedURLs)
    }

    /// "Delete photos" in Settings. Keeps the current wallpapers so the desktop
    /// survives, and drops the prefetch queue along with the files.
    func clearCache() {
        let onScreen = WallpaperSetter.currentWallpaperURLs()
        prefetched.removeAll()
        cache.clear(keeping: onScreen)
    }
}
