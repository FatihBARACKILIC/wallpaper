import AppKit
import Foundation

/// Downloads photos to Application Support and keeps the folder within the
/// user's storage limit.
///
/// Filenames are built so a photo can be traced back to Unsplash by eye:
///   `2026-09-10 — Ales Krivec — misty-mountain-lake — Ry9WBo3qmoc.jpg`
/// The trailing component is the photo ID, so `unsplash.com/photos/<id>` works.
@Observable
final class ImageCache {
    struct Stats: Equatable {
        var count = 0
        var bytes: Int64 = 0

        var formattedBytes: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    private(set) var stats = Stats()

    /// Where the photos live, for the "Show in Finder" button.
    var folder: URL { directory }

    /// Which photo each cached file is, so a file can be re-used later with
    /// proper attribution. Kept beside the photo folder rather than inside it,
    /// so it is never counted towards the storage limit or evicted.
    private var index: [String: Photo] = [:]
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
        refreshStats()
    }

    // MARK: - Index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: Photo].self, from: data)
        else { return }
        index = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Everything on disk we still know the provenance of. Used to keep
    /// rotating when Unsplash is out of reach.
    func entries() -> [(photo: Photo, url: URL)] {
        index.compactMap { filename, photo in
            let url = directory.appending(path: filename)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return (photo, url)
        }
    }

    /// Forgets index entries whose file is gone, so the index cannot outgrow
    /// the folder it describes.
    private func pruneIndex() {
        let existing = Set(contents().map(\.url.lastPathComponent))
        let before = index.count
        index = index.filter { existing.contains($0.key) }
        if index.count != before { saveIndex() }
    }

    // MARK: - Downloading

    /// Downloads `photo` sized for `pixelSize` and returns the local file.
    /// Re-uses an existing file when the same photo is already cached.
    func download(_ photo: Photo, pixelSize: CGSize) async throws -> URL {
        let destination = directory.appending(path: filename(for: photo))
        if fileManager.fileExists(atPath: destination.path) {
            if index[destination.lastPathComponent] == nil {
                index[destination.lastPathComponent] = photo
                saveIndex()
            }
            return destination
        }

        guard let remote = photo.downloadURL(
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height)
        ) else {
            throw UnsplashError.unexpectedStatus(-1)
        }

        let (temporary, response) = try await session.download(from: remote)
        defer { try? fileManager.removeItem(at: temporary) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UnsplashError.unexpectedStatus(http.statusCode)
        }

        // A partially written file must never become a wallpaper, so move into
        // place only once the download is complete.
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        setWhereFrom(photo, on: destination)

        index[destination.lastPathComponent] = photo
        saveIndex()
        refreshStats()

        return destination
    }

    // MARK: - Naming

    private func filename(for photo: Photo) -> String {
        let date = Self.dateFormatter.string(from: Date())
        var parts = [date, Self.sanitize(photo.user.name)]

        if let caption = photo.caption {
            parts.append(Self.sanitize(caption, joinedBy: "-"))
        }
        parts.append(photo.id)

        // APFS allows 255 bytes; trim the caption rather than the ID.
        var name = parts.joined(separator: " — ")
        while name.utf8.count > 250 - 4, parts.count > 2 {
            parts.remove(at: 2)
            name = parts.joined(separator: " — ")
        }

        return name + ".jpg"
    }

    private static func sanitize(_ text: String, joinedBy separator: String = " ") -> String {
        let cleaned = text
            .replacingOccurrences(of: "—", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:.").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: separator)

        return String(cleaned.prefix(80))
    }

    /// Writes the Unsplash page URL into the file's "Where from" metadata, so
    /// the source survives even if the file is renamed.
    private func setWhereFrom(_ photo: Photo, on url: URL) {
        let sources = [photo.webURL, photo.photographerURL].compactMap { $0?.absoluteString }
        guard let plist = try? PropertyListSerialization.data(
            fromPropertyList: sources, format: .binary, options: 0
        ) else { return }

        _ = plist.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0)
        }
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
    func enforce(_ limit: StorageLimit, pinned: Set<URL>) {
        guard limit.isEnabled else {
            pruneIndex()
            refreshStats()
            return
        }

        let pinnedPaths = Set(pinned.map(\.standardizedFileURL.path))
        let files = contents().sorted { $0.created < $1.created }

        var count = files.count
        var bytes = files.reduce(Int64(0)) { $0 + $1.size }

        for file in files where count > limit.maxPhotos || bytes > limit.maxBytes {
            guard !pinnedPaths.contains(file.url.standardizedFileURL.path) else { continue }
            guard (try? fileManager.removeItem(at: file.url)) != nil else { continue }
            count -= 1
            bytes -= file.size
        }

        pruneIndex()
        refreshStats()
    }

    /// Deletes every cached photo except the ones currently on screen.
    func clear(keeping pinned: Set<URL>) {
        let pinnedPaths = Set(pinned.map(\.standardizedFileURL.path))
        for file in contents() where !pinnedPaths.contains(file.url.standardizedFileURL.path) {
            try? fileManager.removeItem(at: file.url)
        }
        pruneIndex()
        refreshStats()
    }

    // MARK: - Inspection

    private struct Entry {
        let url: URL
        let size: Int64
        let created: Date
    }

    private func contents() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
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

    private func refreshStats() {
        let files = contents()
        stats = Stats(count: files.count, bytes: files.reduce(0) { $0 + $1.size })
    }
}
