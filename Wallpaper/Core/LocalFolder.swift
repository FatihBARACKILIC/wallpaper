import CoreGraphics
import Foundation
import ImageIO

enum LocalFolderError: LocalizedError {
    case unavailable(String)
    case noImages(String)
    /// Every photo in the folder is one the user asked never to see again.
    /// Unlike an API source, a fresh draw here is the same files and the same
    /// verdicts, so retrying would change nothing.
    case allBlocked(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path):
            "The folder \(path) isn't there any more. It may have been moved, renamed, or be on a drive that isn't plugged in."
        case .noImages(let path):
            "No images found in \(path)."
        case .allBlocked(let path):
            "Every photo in \(path) is one you asked never to see again. Unblock some in Settings \u{203A} History."
        }
    }
}

/// A folder of the user's own photos.
///
/// The files here are *not* the app's. They are never copied into the cache,
/// never renamed and never evicted — the wallpaper is set straight from where
/// the file already lies. That is why `Artwork.Origin` distinguishes
/// `.localFile` from `.remote` at all: everything that deletes things keys off
/// it.
///
/// Costs no network and no API request, which also means a folder-only setup
/// works with no keys and no connection at all.
///
/// `nonisolated` on purpose. A folder can hold thousands of files, and walking
/// it is the one part of a wallpaper change whose cost grows with what the user
/// happens to own — so the whole pick runs off the main actor. A big folder may
/// make a change slower; it must never make the menu stutter.
nonisolated enum LocalFolder {
    /// Every image in `folder`, including its subfolders.
    ///
    /// Hidden files are skipped, and so are package contents — a `.photoslibrary`
    /// or an `.app` bundle is full of images nobody means to see on their desktop.
    static func images(in folder: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw LocalFolderError.unavailable(folder.path) }

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw LocalFolderError.unavailable(folder.path) }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard ImageFile.isImage(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            found.append(url)
        }

        guard !found.isEmpty else { throw LocalFolderError.noImages(folder.path) }
        return found
    }

    /// Picks `count` images at random.
    ///
    /// Runs on a background executor: the scan, the "never show again" filter
    /// and the header reads all grow with the size of the folder, and a change
    /// must not hold the main actor for as long as the user's archive is large.
    ///
    /// Avoids what is already on screen so the desktop visibly changes, but
    /// gives that up rather than returning nothing — a folder holding a single
    /// photo should still work.
    ///
    /// `blocked` holds the `Artwork.key`s of photos the user asked never to see
    /// again. It is applied before anything else: a blocked photo is not a
    /// photo this folder can offer, even when it is the only one left.
    ///
    /// `screenRatio` is the shape the photo has to fill. Both API sources ask
    /// their provider for landscape photos — Unsplash by `orientation`,
    /// Wallhaven by `ratios` — and a folder had no equivalent, so a folder of
    /// phone photos put portraits on a widescreen desktop with most of each one
    /// cropped away. Passing it in makes the same promise here. A preference,
    /// not a filter: photos are ordered, never dropped, so a folder holding
    /// nothing but portraits still works exactly as before.
    static func randomArtworks(
        count: Int,
        from source: Source,
        avoiding inUse: Set<URL>,
        blocked: Set<String> = [],
        fitting screenRatio: Double? = nil
    ) async throws -> [Artwork] {
        let folder = source.folderURL
        return try await Task.detached(priority: .utility) {
            try pick(count: count, in: folder, avoiding: inUse, blocked: blocked, fitting: screenRatio)
        }.value
    }

    /// The pick itself, in file terms.
    ///
    /// Everything up to the last step deals in URLs rather than `Artwork`:
    /// describing every file meant a folder of five thousand photos built five
    /// thousand values on every change in order to use one of them. Only the
    /// handful actually returned are described.
    private static func pick(
        count: Int,
        in folder: URL,
        avoiding inUse: Set<URL>,
        blocked: Set<String>,
        fitting screenRatio: Double?
    ) throws -> [Artwork] {
        let all = try images(in: folder)

        let allowed = blocked.isEmpty ? all : all.filter { !blocked.contains(key(for: $0)) }
        // A folder whose every photo is blocked has nothing to offer. Source
        // specific, so the next source gets a turn rather than the desktop
        // freezing — but said in its own words, because "no images found" would
        // send the user looking for a problem with the folder.
        guard !allowed.isEmpty else { throw LocalFolderError.allBlocked(folder.path) }

        // Standardising a path is not free, so it is only done when there is
        // something to compare it against.
        let fresh = inUse.isEmpty
            ? allowed
            : allowed.filter { !inUse.contains($0.standardizedFileURL) }
        let pool = fresh.isEmpty ? allowed : fresh

        var chosen = shortlist(from: pool, count: max(1, count), screenRatio: screenRatio)
        // Fewer photos in the folder than screens: repeat rather than leave a
        // screen undressed.
        while chosen.count < count, let first = chosen.first {
            chosen.append(first)
        }

        return chosen.map(artwork(for:))
    }

    /// What `Artwork.key` would be for this file, without building one.
    private static func key(for file: URL) -> String {
        Artwork.key(provider: .local, id: file.standardizedFileURL.path)
    }

    // MARK: - Fitting the screen

    /// How many files are measured before the draw stops caring which fits best.
    ///
    /// Reading a size is only the file's header — nothing is decoded — but it
    /// is not free: measured at 0.09 ms for a JPEG and 0.97 ms for a 6K HEIC.
    /// A folder can hold thousands of files and this runs on every change, so
    /// the sample is capped rather than the whole folder measured. Sixty is
    /// comfortably more than the dozen or so a draw asks for.
    private static let fitSampleLimit = 60

    /// The fraction of a photo thrown away when it is scaled to fill a screen.
    ///
    /// 0 when the two shapes match, climbing towards 1 as they diverge: a 4:3
    /// photo loses a quarter of itself on a 16:9 display, and a 3:4 photo from
    /// a phone loses well over half. Symmetric, because a panorama on a square
    /// display is cropped just as hard the other way.
    static func cropFraction(photo: CGSize, screenRatio: Double) -> Double {
        guard photo.width > 0, photo.height > 0, screenRatio > 0 else { return 0 }
        let photoRatio = Double(photo.width / photo.height)
        return 1 - min(photoRatio, screenRatio) / max(photoRatio, screenRatio)
    }

    /// Picks `count` files, preferring the ones that fit the screen.
    ///
    /// The pool is shuffled first, so what gets measured is a random sample and
    /// the same handful of well-shaped files is not returned every time. A file
    /// whose size cannot be read sorts last but stays in the list, for the same
    /// reason an unmeasured brightness does: "nobody knows" is not "bad fit".
    private static func shortlist(from pool: [URL], count: Int, screenRatio: Double?) -> [URL] {
        let shuffled = pool.shuffled()
        guard let screenRatio, shuffled.count > count else {
            return Array(shuffled.prefix(count))
        }

        let ranked = shuffled.prefix(fitSampleLimit).enumerated()
            .map { (offset: $0.offset, url: $0.element, crop: crop(of: $0.element, screenRatio: screenRatio)) }
            .sorted { left, right in
                switch (left.crop, right.crop) {
                case let (a?, b?) where a != b: return a < b
                case (nil, _?): return false
                case (_?, nil): return true
                // `sorted` is not stable, so the shuffle is preserved by hand.
                default: return left.offset < right.offset
                }
            }

        return ranked.prefix(count).map(\.url)
    }

    private static func crop(of file: URL, screenRatio: Double) -> Double? {
        pixelSize(of: file).map { cropFraction(photo: $0, screenRatio: screenRatio) }
    }

    /// The photo's dimensions, straight from the file header. Nothing is
    /// decoded, so this costs a fraction of a millisecond rather than the ~60 ms
    /// a brightness measurement takes.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { return nil }

        return CGSize(width: width, height: height)
    }

    static func artwork(for file: URL) -> Artwork {
        Artwork(
            id: file.standardizedFileURL.path,
            provider: .local,
            origin: .localFile(file),
            title: file.deletingPathExtension().lastPathComponent.nilIfEmpty,
            creator: nil,
            creatorURL: nil,
            webURL: nil,
            downloadLocation: nil
        )
    }

    /// How many images a folder holds, for the source list. Returns `nil` when
    /// the folder cannot be read, which is what the UI shows as "unavailable".
    static func imageCount(in folder: URL) -> Int? {
        try? images(in: folder).count
    }
}
