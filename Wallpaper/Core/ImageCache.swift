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

    private let directory: URL
    private let session: URLSession
    private let fileManager = FileManager.default

    init(session: URLSession = .shared, directory: URL? = nil) {
        self.session = session
        self.directory = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wallpaper/Photos", directoryHint: .isDirectory)

        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        refreshStats()
    }

    // MARK: - Downloading

    /// Downloads `photo` sized for `pixelSize` and returns the local file.
    /// Re-uses an existing file when the same photo is already cached.
    func download(_ photo: Photo, pixelSize: CGSize) async throws -> URL {
        let destination = directory.appending(path: filename(for: photo))
        if fileManager.fileExists(atPath: destination.path) { return destination }

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

        refreshStats()
    }

    /// Deletes every cached photo except the ones currently on screen.
    func clear(keeping pinned: Set<URL>) {
        let pinnedPaths = Set(pinned.map(\.standardizedFileURL.path))
        for file in contents() where !pinnedPaths.contains(file.url.standardizedFileURL.path) {
            try? fileManager.removeItem(at: file.url)
        }
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
