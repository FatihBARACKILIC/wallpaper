import AppKit
import Foundation

enum CacheError: LocalizedError {
    /// A photo that lives in one of the user's own folders was handed to the
    /// cache. Nothing should ever copy those.
    case notDownloadable
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notDownloadable: "That photo has nothing to download."
        case .badResponse(let code): "Downloading the photo failed (HTTP \(code))."
        }
    }
}

/// Downloads photos to Application Support and keeps the folder within the
/// user's storage limit.
///
/// Filenames are built so a photo can be traced back to its source by eye:
///   `2026-09-10 — Ales Krivec — misty-mountain-lake — Ry9WBo3qmoc.jpg`
/// The trailing component is the photo's ID, so `unsplash.com/photos/<id>` works.
///
/// Only downloaded photos live here. A photo from one of the user's own folders
/// is never copied in — it is used where it lies, so nothing in this type can
/// ever rename or delete it.
///
/// The index lives in memory and is answered from there; the disk is only ever
/// touched to walk the folder or to move, delete and record files, and those
/// are the parts that run off the main actor.
@Observable
final class ImageCache {
    struct Stats: Equatable {
        var count = 0
        var bytes: Int64 = 0

        var formattedBytes: String {
            Self.formatter.string(fromByteCount: bytes)
        }

        /// Held rather than built per call: this is read from a view body, and
        /// a formatter is not a cheap thing to make.
        private static let formatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()
    }

    private(set) var stats = Stats()

    /// Where the photos live, for the "Show in Finder" button.
    var folder: URL { directory }

    /// Which photo each cached file is, so a file can be re-used later with
    /// proper attribution. Kept beside the photo folder rather than inside it,
    /// so it is never counted towards the storage limit or evicted.
    private var index: [String: Artwork] = [:] {
        didSet { filenamesByKey = Self.reverseIndex(index) }
    }

    /// `Artwork.key` to filename. Every pinned photo is looked up on every
    /// housekeep, which is often enough that scanning the index for each one
    /// was the wrong shape.
    private var filenamesByKey: [String: String] = [:]

    private var indexURL: URL {
        directory.deletingLastPathComponent().appending(path: "photo-index.json")
    }

    private let directory: URL
    private let session: URLSession
    private let fileManager = FileManager.default

    init(session: URLSession = .shared, directory: URL? = nil) {
        self.session = session
        self.directory = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wallpaper/Photos", directoryHint: .isDirectory)

        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        loadIndex()
        refreshStats(from: Self.listing(of: self.directory))
    }

    // MARK: - Index

    private static func reverseIndex(_ index: [String: Artwork]) -> [String: String] {
        index.reduce(into: [:]) { result, pair in
            result[pair.value.key] = pair.key
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: Artwork].self, from: data)
        else { return }
        index = decoded
    }

    /// Written on the main actor on purpose: the file holds at most a few
    /// hundred short entries — measured under a kilobyte for a typical cache —
    /// and an atomic write of that size costs less than the bookkeeping needed
    /// to keep two writes in order if they were handed to a background task.
    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Everything on disk we still know the provenance of. Used to keep
    /// rotating when the network is out of reach.
    func entries() -> [(artwork: Artwork, url: URL)] {
        index.compactMap { filename, artwork in
            let url = directory.appending(path: filename)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return (artwork, url)
        }
    }

    /// The cached file for one photo, if it is still on disk.
    ///
    /// Found through the index rather than by rebuilding the filename: the name
    /// carries the date the photo was downloaded, so the same photo fetched
    /// again next week is a different filename. A photo remembered in the
    /// history or pinned as a favourite has to be recognised whatever day it
    /// arrived.
    func existingFile(for artwork: Artwork) -> URL? {
        guard case .remote = artwork.origin, let filename = filenamesByKey[artwork.key] else { return nil }

        let url = directory.appending(path: filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes a downloaded photo and forgets it, so "never show again" does
    /// not leave the file sitting in the cache taking up the user's storage
    /// limit.
    ///
    /// A photo from one of the user's own folders is not the app's to delete,
    /// and is not in the cache to begin with — it leaves here untouched.
    func forget(_ artwork: Artwork) {
        guard case .remote = artwork.origin else { return }

        var removed = Stats()
        for (filename, entry) in index where entry.key == artwork.key {
            let url = directory.appending(path: filename)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if (try? fileManager.removeItem(at: url)) != nil {
                removed.count += 1
                removed.bytes += size
            }
            index[filename] = nil
        }
        saveIndex()
        // Counted down rather than recounted: this runs on the "never show
        // again" path, which already has a wallpaper change to get through.
        stats = Stats(
            count: max(0, stats.count - removed.count),
            bytes: max(0, stats.bytes - removed.bytes)
        )
    }

    /// Forgets index entries whose file is gone, so the index cannot outgrow
    /// the folder it describes. Takes the listing it was going to need anyway
    /// rather than walking the folder again.
    private func pruneIndex(against files: [Entry]) {
        let existing = Set(files.map(\.url.lastPathComponent))
        let before = index.count
        index = index.filter { existing.contains($0.key) }
        if index.count != before { saveIndex() }
    }

    /// Updates what the index says a file is.
    ///
    /// Used for the one fact that can only be learned after the download: how
    /// light the photo actually is. The providers that send a dominant colour
    /// give a good enough guess to rank a batch by, but the file itself is the
    /// truth, and the index is what the cache fallback ranks from later.
    func record(_ artwork: Artwork, at url: URL) {
        let filename = url.lastPathComponent
        guard index[filename] != artwork else { return }
        index[filename] = artwork
        saveIndex()
    }

    // MARK: - Downloading

    /// Downloads `artwork` sized for `pixelSize` — or at its own size when that
    /// is `nil` — and returns the local file. Re-uses an existing file when the
    /// same photo is already cached.
    ///
    /// A photo that is already a file on this Mac never reaches here; the
    /// manager applies those in place.
    func download(_ artwork: Artwork, pixelSize: CGSize?) async throws -> URL {
        guard !artwork.origin.isLocalFile else { throw CacheError.notDownloadable }

        let destination = directory.appending(path: filename(for: artwork))
        if fileManager.fileExists(atPath: destination.path) {
            if index[destination.lastPathComponent] == nil {
                index[destination.lastPathComponent] = artwork
                saveIndex()
            }
            return destination
        }

        guard let remote = artwork.downloadURL(pixelSize: pixelSize) else {
            throw CacheError.notDownloadable
        }

        let (temporary, response) = try await session.download(from: remote)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? fileManager.removeItem(at: temporary)
            throw CacheError.badResponse(http.statusCode)
        }

        let sources = [artwork.webURL, artwork.creatorURL].compactMap { $0?.absoluteString }
        try await Task.detached(priority: .utility) {
            // A partially written file must never become a wallpaper, so move
            // into place only once the download is complete.
            defer { try? FileManager.default.removeItem(at: temporary) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            setWhereFrom(sources, on: destination)
        }.value

        index[destination.lastPathComponent] = artwork
        saveIndex()
        // One file arrived and its size is one `stat` away, so the folder is
        // not walked again for a number we can add. `enforce` recounts from its
        // own listing moments later anyway.
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        stats = Stats(count: stats.count + 1, bytes: stats.bytes + size)

        return destination
    }

    // MARK: - Naming

    private func filename(for artwork: Artwork) -> String {
        let date = Self.dateFormatter.string(from: Date())
        // A NASA picture with no copyright holder is public domain and names
        // nobody, so the provider stands in rather than leaving a gap.
        var parts = [date, Self.sanitize(artwork.creator ?? artwork.provider.displayName)]

        // A Wallhaven upload has no caption and carries its ID as a title;
        // repeating it either side of the separator names nothing twice.
        if let title = artwork.title, title != artwork.id {
            parts.append(Self.sanitize(title, joinedBy: "-"))
        }
        parts.append(Self.sanitize(artwork.id, joinedBy: "-"))

        // APFS allows 255 bytes; trim the title rather than the ID.
        var name = parts.joined(separator: " — ")
        while name.utf8.count > 250 - 6, parts.count > 2 {
            parts.remove(at: 2)
            name = parts.joined(separator: " — ")
        }

        return name + "." + artwork.fileExtension
    }

    private static func sanitize(_ text: String, joinedBy separator: String = " ") -> String {
        let words = text
            .replacingOccurrences(of: "—", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:.").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }

        // Cut at a word boundary rather than mid-word, so the name still reads
        // as a phrase instead of trailing off with a stray separator.
        var result = ""
        for word in words {
            let candidate = result.isEmpty ? word : result + separator + word
            if candidate.count > 60 { break }
            result = candidate
        }

        return result.isEmpty ? String(words.first?.prefix(60) ?? "") : result
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Housekeeping

    /// Evicts oldest-first until the folder fits `limit`. Files in `pinned` are
    /// never removed — they are the current wallpapers and the prefetched next
    /// photo, which would break the desktop or waste the prefetch.
    ///
    /// Walks the folder once. It used to walk it three times: once to sort, once
    /// to prune the index and once to recount, and all three on the main actor
    /// with a `stat` per file.
    func enforce(_ limit: StorageLimit, pinned: Set<URL>) async {
        let directory = directory
        var files = await Task.detached(priority: .utility) { Self.listing(of: directory) }.value

        guard limit.isEnabled else {
            pruneIndex(against: files)
            refreshStats(from: files)
            return
        }

        let pinnedPaths = Set(pinned.map(\.standardizedFileURL.path))

        // Files with no index entry go first: without knowing which photo they
        // are we cannot credit the photographer, so they can never be re-used
        // and would only crowd out photos that can.
        files.sort { left, right in
            let leftKnown = index[left.url.lastPathComponent] != nil
            let rightKnown = index[right.url.lastPathComponent] != nil
            if leftKnown != rightKnown { return !leftKnown }
            return left.created < right.created
        }

        var count = files.count
        var bytes = files.reduce(Int64(0)) { $0 + $1.size }
        var doomed: Set<URL> = []

        for file in files where count > limit.maxPhotos || bytes > limit.maxBytes {
            guard !pinnedPaths.contains(file.url.standardizedFileURL.path) else { continue }
            doomed.insert(file.url)
            count -= 1
            bytes -= file.size
        }

        let survivors = await delete(doomed, from: files)
        pruneIndex(against: survivors)
        refreshStats(from: survivors)
    }

    /// Deletes every cached photo except the ones currently on screen.
    func clear(keeping pinned: Set<URL>) async {
        let directory = directory
        let files = await Task.detached(priority: .utility) { Self.listing(of: directory) }.value

        let pinnedPaths = Set(pinned.map(\.standardizedFileURL.path))
        let doomed = Set(
            files.map(\.url).filter { !pinnedPaths.contains($0.standardizedFileURL.path) }
        )

        let survivors = await delete(doomed, from: files)
        pruneIndex(against: survivors)
        refreshStats(from: survivors)
    }

    /// Removes files off the main actor and reports what is left, so the caller
    /// never has to walk the folder again to find out.
    private func delete(_ doomed: Set<URL>, from files: [Entry]) async -> [Entry] {
        guard !doomed.isEmpty else { return files }

        let failed = await Task.detached(priority: .utility) { () -> Set<URL> in
            var failed: Set<URL> = []
            for url in doomed where (try? FileManager.default.removeItem(at: url)) == nil {
                failed.insert(url)
            }
            return failed
        }.value

        return files.filter { !doomed.contains($0.url) || failed.contains($0.url) }
    }

    // MARK: - Inspection

    /// One file in the photo folder. `Sendable` because the listing is built
    /// off the main actor and handed back.
    nonisolated struct Entry: Sendable {
        let url: URL
        let size: Int64
        let created: Date
    }

    private nonisolated static func listing(of directory: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }

            return Entry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                created: values.creationDate ?? .distantPast
            )
        }
    }

    private func refreshStats(from files: [Entry]) {
        stats = Stats(count: files.count, bytes: files.reduce(0) { $0 + $1.size })
    }
}

/// Writes the photo's page URL into the file's "Where from" metadata, so the
/// source survives even if the file is renamed. Free-standing and `nonisolated`
/// so it can run beside the move it belongs with, off the main actor.
private nonisolated func setWhereFrom(_ sources: [String], on url: URL) {
    guard !sources.isEmpty,
          let plist = try? PropertyListSerialization.data(
              fromPropertyList: sources, format: .binary, options: 0
          )
    else { return }

    _ = plist.withUnsafeBytes {
        setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0)
    }
}
