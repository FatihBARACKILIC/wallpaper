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
    let wallhaven: WallhavenClient
    let cache: ImageCache
    let scheduler: Scheduler
    /// The last 50 wallpapers, the pinned ones and the blocked ones.
    let library: PhotoLibrary

    /// Where in the history the wallpaper on screen came from, so "Previous
    /// wallpaper" keeps walking back instead of bouncing between two photos.
    ///
    /// Not persisted: after a relaunch the honest answer is "the top", and a
    /// stale cursor would start the walk somewhere the user did not leave it.
    private(set) var historyCursor: Int?

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
        wallhaven: WallhavenClient = WallhavenClient(),
        cache: ImageCache = ImageCache(),
        scheduler: Scheduler = Scheduler(),
        library: PhotoLibrary? = nil
    ) {
        self.settings = settings
        self.client = client
        self.nasa = nasa
        self.wallhaven = wallhaven
        self.cache = cache
        self.scheduler = scheduler
        // Derived from the cache rather than worked out a second time, so there
        // is one answer to where the app's data lives.
        self.library = library ?? PhotoLibrary(directory: cache.folder.deletingLastPathComponent())
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

    /// Replaces a resolved location that has gone stale.
    ///
    /// Launch is the one moment this is worth spending: a Mac that has crossed
    /// a continent since the coordinate was stored would compute the wrong
    /// sunrise until somebody noticed. It costs a Wi-Fi lookup at most once a
    /// month, asks for nothing the user has not already granted, and a failure
    /// is silent — the stored coordinate is still a better answer than none.
    func refreshLocationIfStale() async {
        let setting = settings.settings.sunlight
        guard setting.isEnabled, setting.isAutomatic, setting.coordinate != nil, setting.isStale
        else { return }

        guard let coordinate = try? await CurrentLocation.request() else { return }
        settings.update {
            $0.sunlight.coordinate = coordinate
            $0.sunlight.updatedAt = Date()
        }
        Log.wallpaper.info("location refreshed")
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
            remember(batch)
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
        return try await fetchAndDownload(count: count, sunlight: sunlight(at: Date()))
    }

    // MARK: - Matching the sky

    /// How bright a photo the desktop should be wearing at `date`, or `nil`
    /// when the user has not asked for this or there is nowhere to compute from.
    private func sunlight(at date: Date) -> Sunlight? {
        let setting = settings.settings.sunlight
        guard setting.isUsable, let coordinate = setting.coordinate else { return nil }
        return SolarPosition.sunlight(at: coordinate, date: date)
    }

    /// What the menu says about the sky right now. `nil` when the feature is
    /// off, so the menu shows nothing rather than an explanation of a setting
    /// the user never turned on.
    var currentSunlight: Sunlight? { sunlight(at: Date()) }

    /// Sunrise and sunset for today, for the settings row that has to prove
    /// the location is right.
    var todaysSunriseAndSunset: (sunrise: Date, sunset: Date)? {
        guard let coordinate = settings.settings.sunlight.coordinate, coordinate.isValid
        else { return nil }
        return SolarPosition.sunriseAndSunset(at: coordinate)
    }

    /// Orders a draw so the photos that suit the sky come first.
    ///
    /// A preference, never a filter. Nothing is dropped: a draw where every
    /// photo is wrong for the hour still changes the wallpaper, because a
    /// desktop that freezes at dusk is a worse outcome than one wearing a
    /// bright photo at night. Photos whose brightness nobody knows sort last
    /// but stay in the list for the same reason.
    ///
    /// Stable within equal fits, so the shuffle the draw already has is not
    /// undone.
    private func ranked(_ artworks: [Artwork], for sunlight: Sunlight?) async -> [Artwork] {
        guard let sunlight, artworks.count > 1 else { return artworks }

        let measured = await measuringLocalFiles(artworks)
        let target = sunlight.targetBrightness

        return measured
            .enumerated()
            .sorted { left, right in
                let a = left.element.lightness.map { abs($0 - target) }
                let b = right.element.lightness.map { abs($0 - target) }
                switch (a, b) {
                case let (a?, b?) where a != b: return a < b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return left.offset < right.offset
                }
            }
            .map(\.element)
    }

    /// Measures the photos that are already files on this Mac.
    ///
    /// Only those: measuring a remote photo would mean downloading it first,
    /// and downloading a batch to choose one from it is exactly the cost this
    /// feature is built to avoid. Unsplash and Wallhaven send a dominant colour
    /// with the search result instead, so theirs is already known; APOD sends
    /// nothing and is measured after the download it was going to do anyway.
    ///
    /// Capped, and off the main thread: a folder draw is a shortlist, but the
    /// shortlist grows with the screen count and every measurement decodes a
    /// thumbnail.
    private func measuringLocalFiles(_ artworks: [Artwork]) async -> [Artwork] {
        // Worked out here and handed over as plain positions and URLs: the
        // background task measures files and knows nothing about `Artwork`.
        let pending: [(position: Int, url: URL)] = artworks.enumerated()
            .prefix(Self.brightnessSampleLimit)
            .compactMap { index, artwork in
                guard artwork.lightness == nil, artwork.origin.isLocalFile else { return nil }
                return (index, artwork.origin.url)
            }
        guard !pending.isEmpty else { return artworks }

        let measured = await Task.detached(priority: .utility) {
            pending.reduce(into: [Int: Double]()) { result, file in
                result[file.position] = ImageBrightness.lightness(ofFile: file.url)
            }
        }.value

        return artworks.enumerated().map { index, artwork in
            measured[index].map { artwork.withLightness($0) } ?? artwork
        }
    }

    /// How many files a folder draw is willing to measure before it stops
    /// caring which is the best fit.
    ///
    /// Measuring costs about 60 ms for a full-size JPEG with no embedded
    /// thumbnail — measured — so this is a second of background CPU once per
    /// change, and it is sized to the draw rather than guessed: `askFor` adds
    /// ten candidates when the sky is being matched, so twelve covers a
    /// single-screen folder pick without ever leaving files unmeasured.
    private static let brightnessSampleLimit = 12

    /// Picks a source and readies `count` photos from it.
    ///
    /// Sources are tried in random order, and a failure that is specific to one
    /// source moves on to the next: an unplugged drive or a search that matched
    /// nothing should not freeze the desktop of someone who also has three
    /// sources that work. A bad key or an exhausted quota is not source
    /// specific — that is the user's to fix, and it is reported at once.
    private func fetchAndDownload(count: Int, sunlight: Sunlight?) async throws -> [Applied] {
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
                return try await fetch(count: count, from: source, sunlight: sunlight)
            } catch let error where Self.isSourceSpecific(error) {
                Log.wallpaper.info(
                    "source \(source.shortLabel, privacy: .public) unusable, trying another: \(error.localizedDescription, privacy: .public)"
                )
                lastError = error
            }
        }

        throw lastError ?? SetupError.noUsableSources(settings.settings.sources)
    }

    private func fetch(count: Int, from source: Source, sunlight: Sunlight?) async throws -> [Applied] {
        switch source.kind {
        case .folder:
            // Nothing to download: the files are already on this Mac, and they
            // are the user's, so they are used exactly where they lie.
            let inUse = Set(current.map(\.url.standardizedFileURL))
            let files = try LocalFolder.randomArtworks(
                count: askFor(count, sunlight: sunlight),
                from: source,
                avoiding: inUse,
                blocked: library.blockedKeys,
                fitting: screenAspectRatio
            )
            return await ranked(files, for: sunlight)
                .prefix(count)
                .map { Applied(artwork: $0, url: $0.origin.url) }

        case .apod:
            let entries = try await nasa.randomArtworks(count: askFor(count, sunlight: sunlight))
            return try await downloadAll(
                await ranked(allowed(entries, from: source), for: sunlight), count: count
            )

        case .wallhaven:
            let entries = try await wallhaven.randomArtworks(
                count: askFor(count, sunlight: sunlight),
                from: source,
                atLeast: wallhavenMinimumSize
            )
            return try await downloadAll(
                await ranked(allowed(entries, from: source), for: sunlight), count: count
            )

        case .topic, .collection, .search:
            let photos = try await client.randomArtworks(
                count: askFor(count, sunlight: sunlight), from: source
            )
            return try await downloadAll(
                await ranked(allowed(photos, from: source), for: sunlight), count: count
            )
        }
    }

    /// How many photos to ask an API for.
    ///
    /// A blocked photo can turn up in any draw — none of the three APIs knows
    /// what the user has rejected — so over-ask when there is a
    /// block list to filter against. This costs no extra request: both
    /// providers return the whole batch in one call, and only the photos
    /// actually used are downloaded and reported.
    ///
    /// Matching the sky over-asks for the same reason and at the same price:
    /// there has to be a spread of brightnesses to choose the closest from, and
    /// a batch of one is not a choice.
    private func askFor(_ needed: Int, sunlight: Sunlight? = nil) -> Int {
        var count = needed
        if !library.blockedKeys.isEmpty { count += 5 }
        if sunlight != nil { count += 10 }
        return count
    }

    /// Drops the photos the user asked never to see again.
    ///
    /// A draw that was entirely blocked is source specific — the next source
    /// gets a turn — and, unlike a folder, worth retrying: the next draw from
    /// an API is a different set of photos.
    private func allowed(_ artworks: [Artwork], from source: Source) throws -> [Artwork] {
        guard !library.blockedKeys.isEmpty else { return artworks }

        let kept = artworks.filter { !library.isBlocked($0) }
        guard !kept.isEmpty else { throw PickError.everythingBlocked(source) }
        return kept
    }

    private func downloadAll(_ artworks: [Artwork], count: Int) async throws -> [Applied] {
        var results: [Applied] = []
        for (index, artwork) in artworks.prefix(count).enumerated() {
            let size = downloadSize(forScreenAt: index)
            let url = try await cache.download(artwork, pixelSize: size)

            // The file is the truth about how light a photo is; a dominant
            // colour is only a good enough guess to have ranked the batch by.
            // Writing it back is what lets the cache fallback rank too.
            let measured = await measured(artwork, at: url)
            cache.record(measured, at: url)

            results.append(Applied(artwork: measured, url: url))
        }
        return results
    }

    /// Fills in a downloaded photo's brightness from the file itself.
    private func measured(_ artwork: Artwork, at url: URL) async -> Artwork {
        guard settings.settings.sunlight.isEnabled else { return artwork }
        let measured = await Task.detached(priority: .utility) {
            ImageBrightness.lightness(ofFile: url)
        }.value
        return artwork.withLightness(measured)
    }

    /// Whether the failure says "this source won't do" rather than "the app is
    /// misconfigured" or "the network is down".
    private static func isSourceSpecific(_ error: any Error) -> Bool {
        if error is LocalFolderError { return true }
        if error is PickError { return true }
        if case .noPhotosFound = error as? UnsplashError { return true }
        if case .noPhotosFound = error as? NASAError { return true }
        if case .noPhotosFound = error as? WallhavenError { return true }
        return false
    }

    /// The shape a photo has to fill, for the folder draw.
    ///
    /// The largest screen, which is the same basis `downloadSize` falls back
    /// to. In per-screen mode the displays can be different shapes, and one
    /// answer for the whole batch is a better trade than scanning the folder
    /// once per screen — the draw is a handful of photos, not a photo chosen
    /// for each display in turn.
    private var screenAspectRatio: Double? {
        let size = WallpaperSetter.largestScreenPixelSize()
        guard size.width > 0, size.height > 0 else { return nil }
        return Double(size.width / size.height)
    }

    /// The smallest wallpaper Wallhaven may offer.
    ///
    /// Wallhaven cannot resize, so `PhotoResolution` has nothing to shrink —
    /// but a 1280×720 upload stretched over a 5K display is exactly what the
    /// setting exists to prevent. Refusing anything smaller than the screen is
    /// the only lever the API gives, and `.original` wants the same floor: it
    /// asks for more pixels, never fewer.
    private var wallhavenMinimumSize: CGSize {
        settings.settings.photoResolution == .coverAllScreens
            ? WallpaperSetter.coveringPixelSize()
            : WallpaperSetter.largestScreenPixelSize()
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

    // MARK: - History, pins and blocks

    /// Writes what has just gone up into the history and puts the walk-back
    /// cursor past it, so the first step back goes to the photo *before* this
    /// change rather than to one that is on screen right now.
    ///
    /// In per-screen mode one change puts up several photos, and all of them
    /// are now at the front of the list — stepping back means the change
    /// before this one, not the photo on the next display.
    private func remember(_ batch: [Applied]) {
        library.record(batch.map(\.artwork))
        historyCursor = max(0, batch.count - 1)
    }

    /// Whether there is anything further back to go to.
    var canGoBack: Bool { library.entry(before: historyCursor) != nil }

    /// Walks one step back through the history and puts that photo up. Called
    /// again, it keeps walking rather than bouncing between two photos.
    ///
    /// An entry that cannot be produced any more — one of the user's own files
    /// that they have since deleted — is stepped over rather than reported:
    /// the button means "show me the one before", and stopping on a gap would
    /// strand the walk.
    func goBack() async {
        // Without this the walk would step over every entry in turn, since
        // `apply` refuses them all while a change is in flight.
        guard !isChanging else { return }

        var cursor = historyCursor
        while let (index, entry) = library.entry(before: cursor) {
            if await apply(entry.artwork, at: index) { return }
            cursor = index
        }
        notice = "Those earlier wallpapers aren't available any more."
    }

    /// Puts one remembered photo back up, and keeps it there for a full
    /// interval.
    ///
    /// It goes on every screen even in per-screen mode: the user picked one
    /// photo, and there is no basis for deciding which display should get it.
    /// Per-screen resumes at the next rotation.
    ///
    /// Returns whether it worked, which is what lets `goBack` step over a gap.
    @discardableResult
    func apply(_ artwork: Artwork, at cursor: Int? = nil) async -> Bool {
        guard !isChanging else { return false }
        isChanging = true
        defer { isChanging = false }

        cancelRetry()
        status = .working

        do {
            let resolved = try await resolve(artwork)
            try await applyWithTransition([resolved.url])

            current = [Applied(artwork: artwork, url: resolved.url)]
            historyCursor = cursor ?? library.index(of: artwork)
            lastChangeDate = Date()
            status = .idle
            notice = nil
            Log.wallpaper.info("re-applied \(artwork.key, privacy: .public)")

            // Rotation carrying on as scheduled would wipe the user's own
            // choice off the screen moments later.
            scheduler.postpone()

            // Reported only when bytes actually came down. A file that was
            // still on disk was reported the first time it was used.
            if resolved.downloaded {
                await client.reportDownload(for: artwork)
            }
            housekeep()
            return true
        } catch {
            Log.wallpaper.info(
                "could not re-apply \(artwork.key, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            status = .idle
            return false
        }
    }

    /// Where a remembered photo's bytes are now.
    ///
    /// The library is kept in `Artwork` terms precisely because the file may be
    /// gone: a download that has since been evicted is fetched again, while one
    /// of the user's own files is used where it lies — and if they deleted it,
    /// nothing can bring it back.
    private func resolve(_ artwork: Artwork) async throws -> (url: URL, downloaded: Bool) {
        if case .localFile(let url) = artwork.origin {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PickError.fileGone(artwork)
            }
            return (url, false)
        }

        if let existing = cache.existingFile(for: artwork) {
            return (existing, false)
        }

        return (try await cache.download(artwork, pixelSize: downloadSize(forScreenAt: 0)), true)
    }

    /// Pins or unpins a photo. The cache is re-checked either way: a file it
    /// was free to evict a moment ago is now one it has to keep, and the other
    /// way round.
    func toggleFavorite(_ artwork: Artwork) {
        library.toggleFavorite(artwork)
        housekeep()
    }

    /// "Never show again."
    ///
    /// Blocking has to act now, not at the next change: the photo the user just
    /// rejected is usually the one on screen, and the one queued up behind it.
    func block(_ artwork: Artwork) async {
        library.block(artwork)

        // A blocked photo sitting in the queue would be the very next thing on
        // the desktop.
        prefetched.removeAll { $0.artwork.key == artwork.key }

        if current.contains(where: { $0.artwork.key == artwork.key }) {
            await changeNow()
        }

        // Only once it is off the screen — deleting the file while it is still
        // the wallpaper would leave the desktop pointing at nothing. A photo
        // from the user's own folder is not the app's to delete; `forget`
        // refuses those.
        if !current.contains(where: { $0.artwork.key == artwork.key }) {
            cache.forget(artwork)
        }
        prefetchNext()
    }

    func unblock(_ artwork: Artwork) {
        library.unblock(artwork)
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

    /// A source offered photos, but not ones that could be used.
    enum PickError: LocalizedError {
        /// Every photo in the draw was on the user's "never show again" list.
        /// The default recovery — retry with backoff — is the right one: the
        /// next draw from an API is a different set of photos.
        case everythingBlocked(Source)
        /// A remembered photo whose file the user has since deleted. Only a
        /// photo from one of their own folders can be lost this way; a
        /// downloaded one is fetched again.
        case fileGone(Artwork)

        var errorDescription: String? {
            switch self {
            case .everythingBlocked(let source):
                "Every photo \(source.shortLabel) offered is one you asked never to see again."
            case .fileGone(let artwork):
                "\(artwork.shortLabel) isn't on this Mac any more."
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
        case let error as WallhavenError:
            // Wallhaven's quota is 45 a minute, not an hour, so it names no
            // reset time: by the time the user reads this it has already
            // cleared.
            if case .rateLimited = error { ("Wallhaven", nil) } else { nil }
        default:
            nil
        }

        guard let limited else {
            return "Couldn't fetch a new photo — showing one you already have."
        }
        guard let resetsAt = limited.resetsAt else {
            return "\(limited.name) request limit reached — showing a photo you already have."
        }

        let time = resetsAt.formatted(date: .omitted, time: .shortened)
        return "\(limited.name) hourly limit reached — showing a photo you already have. New ones at \(time)."
    }

    /// Picks photos already on disk, avoiding the ones on screen so the
    /// wallpaper visibly changes. Returns false when there is nothing to fall
    /// back to, which leaves the current wallpaper alone.
    private func applyFromCache() async -> Bool {
        let inUse = Set(current.map(\.url.standardizedFileURL))
        // "Never show again" holds here too: the disk is not an excuse to put
        // back a photo the user rejected.
        let candidates = cache.entries().filter {
            !inUse.contains($0.url.standardizedFileURL) && !library.isBlocked($0.artwork)
        }
        guard !candidates.isEmpty else {
            Log.wallpaper.debug("no cached photo to fall back to")
            return false
        }

        // The index remembers how light each cached photo is, so an outage is
        // no reason to stop matching the sky.
        let ordered = await ranked(candidates.shuffled().map(\.artwork), for: currentSunlight)
        let byKey = Dictionary(candidates.map { ($0.artwork.key, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen = ordered.compactMap { byKey[$0.key] }.prefix(neededPhotoCount).map { $0 }
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
        remember(current)
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
        case let error as WallhavenError:
            switch error {
            case .invalidAPIKey:
                // Wallhaven is never sent a key, so this cannot be the user's
                // to fix; treat it as the server misbehaving.
                return .retry(after: backoffDelay)

            case .noPhotosFound:
                // The search matched nothing even without a minimum size, so a
                // fresh draw will match nothing either.
                return .userMustAct

            case .rateLimited:
                // 45 a minute, and it clears on a rolling window rather than on
                // the hour, so the ordinary backoff is already long enough.
                return .retry(after: backoffDelay)

            case .unexpectedStatus:
                return .retry(after: backoffDelay)

            case .transport(let underlying):
                return Self.isOffline(underlying) ? .waitForNetwork : .retry(after: backoffDelay)
            }

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

    /// 30s, 1m, 2m, 5m, 15m, then flat. Long enough not to hammer a provider,
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

            // Matched against the sky at the moment this photo will go up, not
            // the moment it is fetched. On a twelve-hour interval those are
            // opposite ends of the day, and picking for now would put a noon
            // photo on a midnight desktop.
            let due = scheduler.nextChangeDate ?? Date()

            // A failed prefetch is not worth surfacing — the next change will
            // fetch fresh photos and report the error then.
            if let batch = try? await fetchAndDownload(count: needed, sunlight: sunlight(at: due)) {
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

    /// Files that must survive eviction: what is on screen now, what is queued
    /// for the next change, and what the user pinned.
    private var pinnedURLs: Set<URL> {
        WallpaperSetter.currentWallpaperURLs()
            .union(prefetched.map(\.url))
            .union(current.map(\.url))
            .union(favoriteURLs)
    }

    /// The cached files behind the pinned photos.
    ///
    /// Pinning means "keep this", and eviction has to honour it — so a long pin
    /// list can hold the folder above the storage limit. That is the right way
    /// round: the alternative is deleting a photo the user asked to keep.
    private var favoriteURLs: Set<URL> {
        Set(library.favorites.compactMap { cache.existingFile(for: $0.artwork) })
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
