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

    /// A photo and the file it was applied from — a download in the cache, or
    /// one of the user's own files where it already lies.
    struct Applied: Codable, Hashable {
        var artwork: Artwork
        var url: URL

        enum CodingKeys: String, CodingKey {
            // Persisted as "photo" before the app had more than one provider.
            // Kept under the old name so an upgrade does not forget what is
            // already on screen.
            case artwork = "photo"
            case url
        }

        /// A photo from the user's own folder can be deleted behind the app's
        /// back; re-applying a file that is gone would clear the desktop.
        var stillExists: Bool {
            !artwork.origin.isLocalFile || FileManager.default.fileExists(atPath: url.path)
        }
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
    var currentArtworks: [Artwork] { current.map(\.artwork) }

    let settings: SettingsStore
    let client: UnsplashClient
    let nasa: NASAClient
    let cache: ImageCache
    let scheduler: Scheduler

    /// Photos already readied for the next change, so applying a wallpaper
    /// touches the disk rather than the network.
    ///
    /// Persisted, because it used to be lost on quit: `start()` fires an
    /// overdue change *before* it prefetches, so the first change after every
    /// launch went to the network — and on a long interval that is the only
    /// change the user ever sees.
    private var prefetched: [Applied] = WallpaperManager.restorePrefetched() {
        didSet { persistPrefetched() }
    }
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
        nasa: NASAClient = NASAClient(),
        cache: ImageCache = ImageCache(),
        scheduler: Scheduler = Scheduler()
    ) {
        self.settings = settings
        self.client = client
        self.nasa = nasa
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

    private static let prefetchedKey = "prefetchedWallpapers"

    /// Checks every file, not just the ones from a user folder the way
    /// `stillExists` does. While the app runs, a queued cache file is pinned
    /// against eviction; across a quit nothing pins it, so the only honest
    /// answer is to look at the disk.
    private static func restorePrefetched() -> [Applied] {
        guard let data = UserDefaults.standard.data(forKey: prefetchedKey),
              let decoded = try? JSONDecoder().decode([Applied].self, from: data)
        else { return [] }

        return decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func persistPrefetched() {
        guard let data = try? JSONEncoder().encode(prefetched) else { return }
        UserDefaults.standard.set(data, forKey: Self.prefetchedKey)
    }

    /// Ready means at least one source can actually be drawn from right now.
    ///
    /// Not "has an Unsplash key": a setup made only of local folders needs no
    /// key and no network at all, and demanding one would lock such a user out
    /// of their own photos.
    var isReady: Bool {
        !settings.usableSources.isEmpty
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

        guard !settings.settings.sources.isEmpty else {
            status = .failed("No sources added yet. Add one in Settings.")
            return
        }
        guard !settings.usableSources.isEmpty else {
            status = .failed(SetupError.noUsableSources(settings.settings.sources).localizedDescription)
            return
        }

        status = .working

        do {
            let needed = neededPhotoCount
            let batch = try await takePhotos(count: needed)

            try await applyWithTransition(batch.map(\.url))

            current = batch
            Log.wallpaper.info("wallpaper changed: \(batch.count, privacy: .public) photo(s)")
            lastChangeDate = Date()
            status = .idle
            notice = nil
            consecutiveFailures = 0
            stopNetworkMonitor()

            // Required by the Unsplash guidelines, but never worth failing over.
            // Only Unsplash photos have anything to report; the client ignores
            // the rest.
            for entry in batch {
                await client.reportDownload(for: entry.artwork)
            }

            housekeep()
            prefetchNext()
        } catch {
            await handleFailure(error)
        }
    }

    /// Uses the prefetched photos when they fit, otherwise fetches fresh ones.
    private func takePhotos(count: Int) async throws -> [Applied] {
        if prefetched.count >= count, prefetched.prefix(count).allSatisfy(\.stillExists) {
            let batch = Array(prefetched.prefix(count))
            prefetched.removeFirst(count)
            return batch
        }

        prefetched.removeAll()
        return try await fetchAndDownload(count: count)
    }

    /// Picks a source and readies `count` photos from it.
    ///
    /// Sources are tried in random order, and a failure that is specific to one
    /// source moves on to the next: an unplugged drive or a search that matched
    /// nothing should not freeze the desktop of someone who also has three
    /// sources that work. A bad key or an exhausted quota is not source
    /// specific — that is the user's to fix, and it is reported at once.
    private func fetchAndDownload(count: Int) async throws -> [Applied] {
        var sources = settings.usableSources.shuffled()
        guard !sources.isEmpty else {
            throw SetupError.noUsableSources(settings.settings.sources)
        }

        // On the user's own data allowance, keep only the sources that download
        // nothing. A folder still rotates normally; if there is none, the throw
        // sends this through `handleFailure`, which reaches for the cache before
        // it settles into waiting — the desktop must not freeze for a hotspot
        // any more than it does for an outage.
        if settings.settings.pauseOnExpensiveNetwork,
           let path = await NetworkPath.current(), path.isMetered {
            let free = sources.filter { !$0.kind.provider.needsDownload }
            guard !free.isEmpty else {
                throw path.isExpensive
                    ? MeteredNetworkError.expensive
                    : MeteredNetworkError.constrained
            }
            Log.wallpaper.info(
                "metered connection: limited to \(free.count, privacy: .public) source(s) that download nothing"
            )
            sources = free
        }

        var lastError: (any Error)?
        for source in sources {
            do {
                return try await fetch(count: count, from: source)
            } catch let error where Self.isSourceSpecific(error) {
                Log.wallpaper.info(
                    "source \(source.shortLabel, privacy: .public) unusable, trying another: \(error.localizedDescription, privacy: .public)"
                )
                lastError = error
            }
        }

        throw lastError ?? SetupError.noUsableSources(settings.settings.sources)
    }

    private func fetch(count: Int, from source: Source) async throws -> [Applied] {
        switch source.kind {
        case .folder:
            // Nothing to download: the files are already on this Mac, and they
            // are the user's, so they are used exactly where they lie.
            let inUse = Set(current.map(\.url.standardizedFileURL))
            return try LocalFolder
                .randomArtworks(count: count, from: source, avoiding: inUse)
                .map { Applied(artwork: $0, url: $0.origin.url) }

        case .apod:
            return try await downloadAll(nasa.randomArtworks(count: count), count: count)

        case .topic, .collection, .search:
            return try await downloadAll(client.randomArtworks(count: count, from: source), count: count)
        }
    }

    private func downloadAll(_ artworks: [Artwork], count: Int) async throws -> [Applied] {
        var results: [Applied] = []
        for (index, artwork) in artworks.prefix(count).enumerated() {
            let size = downloadSize(forScreenAt: index)
            results.append(Applied(artwork: artwork, url: try await cache.download(artwork, pixelSize: size)))
        }
        return results
    }

    /// Whether the failure says "this source won't do" rather than "the app is
    /// misconfigured" or "the network is down".
    private static func isSourceSpecific(_ error: any Error) -> Bool {
        if error is LocalFolderError { return true }
        if case .noPhotosFound = error as? UnsplashError { return true }
        if case .noPhotosFound = error as? NASAError { return true }
        return false
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

    /// The app is configured, but not in a way it can act on.
    enum SetupError: LocalizedError {
        /// Sources exist, but every one of them is waiting on a key.
        case noUsableSources([Source])

        var errorDescription: String? {
            switch self {
            case .noUsableSources(let sources):
                let needed = Set(sources.map(\.kind.provider))
                return switch (needed.contains(.unsplash), needed.contains(.apod)) {
                case (true, true):
                    "Your sources need an Unsplash Access Key and a NASA API key. Add them in Settings."
                case (false, true):
                    "The NASA APOD source needs a NASA API key. Add one in Settings."
                default:
                    "Your Unsplash sources need an Access Key. Add one in Settings."
                }
            }
        }
    }

    /// The connection is the user's own data allowance and
    /// `pauseOnExpensiveNetwork` is on, so nothing may be downloaded. Not a
    /// failure — a wait, which is why it recovers through `.waitForNetwork`.
    enum MeteredNetworkError: LocalizedError {
        case expensive
        case constrained

        var errorDescription: String? {
            switch self {
            case .expensive: "On cellular or a hotspot — waiting for Wi-Fi."
            case .constrained: "Low Data Mode is on — waiting for a full-speed network."
            }
        }

        /// Said instead when a photo already on disk could be shown.
        var cacheNotice: String {
            switch self {
            case .expensive: "On a hotspot — showing a photo you already have."
            case .constrained: "Low Data Mode — showing a photo you already have."
            }
        }
    }

    /// What to do about a failed change. Some failures fix themselves, some
    /// need the user, and waiting a whole interval to find out which is no good
    /// when the interval is a week.
    private enum Recovery {
        case retry(after: TimeInterval)
        case waitForNetwork
        case userMustAct

        /// Only worth reaching for the cache when the network is unreachable,
        /// not when the key or the sources are wrong.
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

        // The network is out of reach, but the disk is not: keep rotating
        // through photos already downloaded rather than freezing on one.
        let usedCache = recovery.allowsCacheFallback ? await applyFromCache() : false

        switch recovery {
        case .userMustAct:
            status = .failed(error.localizedDescription)
            notice = nil

        case .waitForNetwork:
            let metered = error as? MeteredNetworkError
            status = usedCache
                ? .idle
                : .waitingForNetwork(metered?.localizedDescription ?? "Offline — will retry when the network is back.")
            notice = usedCache
                ? (metered?.cacheNotice ?? "Offline — showing a photo you already have.")
                : nil
            startNetworkMonitor()

        case .retry(let delay):
            status = usedCache ? .idle : .failed(error.localizedDescription)
            notice = usedCache ? cacheNotice(for: error) : nil
            scheduleRetry(after: delay)
        }
    }

    private func cacheNotice(for error: any Error) -> String {
        let limited: (name: String, resetsAt: Date?)? = switch error {
        case let error as UnsplashError:
            if case .rateLimited(let resetsAt) = error { ("Unsplash", resetsAt) } else { nil }
        case let error as NASAError:
            if case .rateLimited(let resetsAt) = error { ("NASA", resetsAt) } else { nil }
        default:
            nil
        }

        guard let limited else {
            return "Couldn't fetch a new photo — showing one you already have."
        }
        guard let resetsAt = limited.resetsAt else {
            return "\(limited.name) hourly limit reached — showing a photo you already have."
        }

        let time = resetsAt.formatted(date: .omitted, time: .shortened)
        return "\(limited.name) hourly limit reached — showing a photo you already have. New ones at \(time)."
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

        current = chosen.map { Applied(artwork: $0.artwork, url: $0.url) }
        lastChangeDate = Date()
        // No download is reported: nothing was downloaded, and the photo was
        // already reported the first time it was used.
        Log.wallpaper.info("fell back to \(chosen.count, privacy: .public) cached photo(s)")
        return true
    }

    private func recovery(for error: any Error) -> Recovery {
        switch error {
        case is MeteredNetworkError:
            // Nothing is wrong and nothing will fix itself with time: wait for
            // the connection to change, which is exactly what the monitor does.
            return .waitForNetwork

        case let error as UnsplashError:
            switch error {
            case .missingAccessKey, .invalidAccessKey, .noPhotosFound:
                // Nothing retrying can fix — the key or the source has to change.
                return .userMustAct

            case .rateLimited(let resetsAt):
                // Retrying before the quota rolls over just wastes requests.
                return .retry(after: waitForQuota(until: resetsAt))

            case .unexpectedStatus:
                return .retry(after: backoffDelay)

            case .transport(let underlying):
                return Self.isOffline(underlying) ? .waitForNetwork : .retry(after: backoffDelay)
            }

        case let error as NASAError:
            switch error {
            case .missingAPIKey, .invalidAPIKey:
                return .userMustAct

            case .noPhotosFound:
                // Today's random draw was all videos. A fresh draw is a
                // different set of days, so this really does fix itself.
                return .retry(after: backoffDelay)

            case .rateLimited(let resetsAt):
                return .retry(after: waitForQuota(until: resetsAt))

            case .unexpectedStatus:
                return .retry(after: backoffDelay)

            case .transport(let underlying):
                return Self.isOffline(underlying) ? .waitForNetwork : .retry(after: backoffDelay)
            }

        // A folder that is gone and a setup with no usable source both need the
        // user: no amount of retrying will plug a drive back in or type a key.
        case is LocalFolderError, is SetupError:
            return .userMustAct

        default:
            return .retry(after: backoffDelay)
        }
    }

    /// Long enough for the quota to roll over, never shorter than a minute.
    private func waitForQuota(until resetsAt: Date?) -> TimeInterval {
        max(60, (resetsAt?.timeIntervalSinceNow ?? 3600) + 60)
    }

    private static func isOffline(_ error: any Error) -> Bool {
        [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
        ].contains((error as NSError).code)
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
            let snapshot = NetworkPath.Snapshot(path)
            Task { @MainActor [weak self] in
                guard let self, networkMonitor != nil else { return }
                // Reconnecting to the same hotspot is not coming back: keep
                // waiting rather than spending the allowance we just declined.
                guard !(settings.settings.pauseOnExpensiveNetwork && snapshot.isMetered) else { return }
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
