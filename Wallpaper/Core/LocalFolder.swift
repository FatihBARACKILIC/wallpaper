import Foundation

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
enum LocalFolder {
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
    /// Avoids what is already on screen so the desktop visibly changes, but
    /// gives that up rather than returning nothing — a folder holding a single
    /// photo should still work.
    ///
    /// `blocked` holds the `Artwork.key`s of photos the user asked never to see
    /// again. It is applied before anything else: a blocked photo is not a
    /// photo this folder can offer, even when it is the only one left.
    static func randomArtworks(
        count: Int,
        from source: Source,
        avoiding inUse: Set<URL>,
        blocked: Set<String> = []
    ) throws -> [Artwork] {
        let all = try images(in: source.folderURL).map(artwork(for:))

        let allowed = blocked.isEmpty ? all : all.filter { !blocked.contains($0.key) }
        // A folder whose every photo is blocked has nothing to offer. Source
        // specific, so the next source gets a turn rather than the desktop
        // freezing — but said in its own words, because "no images found" would
        // send the user looking for a problem with the folder.
        guard !allowed.isEmpty else { throw LocalFolderError.allBlocked(source.folderURL.path) }

        let fresh = allowed.filter { !inUse.contains($0.origin.url.standardizedFileURL) }
        let pool = fresh.isEmpty ? allowed : fresh

        var chosen = Array(pool.shuffled().prefix(max(1, count)))
        // Fewer photos in the folder than screens: repeat rather than leave a
        // screen undressed.
        while chosen.count < count, let first = chosen.first {
            chosen.append(first)
        }

        return chosen
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
