import Foundation

/// One photo, in the form the rest of the app stores, credits and applies.
///
/// The providers speak different dialects — Unsplash answers with a deep JSON
/// object, NASA APOD with a flat one, a local folder with nothing at all — so
/// each maps into this before anything else sees it. Everything persisted
/// (`photo-index.json`, `currentWallpapers`) is in these terms.
struct Artwork: Codable, Hashable, Identifiable, Sendable {
    enum Provider: String, Codable, Sendable {
        case unsplash
        case apod
        case local

        var displayName: String {
            switch self {
            case .unsplash: "Unsplash"
            case .apod: "NASA APOD"
            case .local: "your Mac"
            }
        }
    }

    /// Where the bytes are.
    ///
    /// This is a safety rule, not a detail. `.remote` files are downloaded into
    /// the cache and may be evicted; `.localFile` ones belong to the user and
    /// are used where they lie — never copied, renamed, evicted or deleted.
    enum Origin: Codable, Hashable, Sendable {
        case remote(URL)
        case localFile(URL)

        var url: URL {
            switch self {
            case .remote(let url), .localFile(let url): url
            }
        }

        var isLocalFile: Bool {
            if case .localFile = self { return true }
            return false
        }
    }

    /// Unique within its provider: an Unsplash ID, an APOD date, a file path.
    let id: String
    let provider: Provider
    let origin: Origin
    /// Caption, APOD title, or the file's own name.
    let title: String?
    /// Photographer or copyright holder. `nil` when nobody is named — a NASA
    /// image with no `copyright` field is public domain, and a file on disk
    /// carries no author.
    let creator: String?
    let creatorURL: URL?
    /// The page this photo came from.
    let webURL: URL?
    /// Unsplash only: the endpoint that must be hit once the photo is used.
    let downloadLocation: String?

    init(
        id: String,
        provider: Provider,
        origin: Origin,
        title: String? = nil,
        creator: String? = nil,
        creatorURL: URL? = nil,
        webURL: URL? = nil,
        downloadLocation: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.origin = origin
        self.title = title
        self.creator = creator
        self.creatorURL = creatorURL
        self.webURL = webURL
        self.downloadLocation = downloadLocation
    }

    /// A URL for the actual bytes, or `nil` for a file already on disk.
    ///
    /// Only Unsplash resizes server-side: its CDN takes `w`/`h` and returns a
    /// screen-sized JPEG instead of a 50 MB original. APOD serves fixed files,
    /// so the resolution setting has nothing to act on there.
    func downloadURL(pixelSize: CGSize?) -> URL? {
        guard case .remote(let remote) = origin else { return nil }
        guard provider == .unsplash, var components = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        else { return remote }

        var items = components.queryItems ?? []
        items.removeAll { ["w", "h", "fit", "crop", "q", "fm", "dpr"].contains($0.name) }

        if let pixelSize {
            items.append(contentsOf: [
                URLQueryItem(name: "w", value: String(Int(pixelSize.width))),
                URLQueryItem(name: "h", value: String(Int(pixelSize.height))),
                URLQueryItem(name: "fit", value: "crop"),
                URLQueryItem(name: "crop", value: "entropy"),
            ])
        }

        // Still transcode: the raw original can be a 50 MB uncompressed file.
        items.append(contentsOf: [
            URLQueryItem(name: "q", value: "85"),
            URLQueryItem(name: "fm", value: "jpg"),
        ])
        components.queryItems = items

        return components.url ?? remote
    }

    /// The extension a downloaded copy should carry. Unsplash is asked for JPEG
    /// explicitly; APOD serves whatever it has, and a PNG saved as `.jpg` would
    /// be a lie to every other app that reads the folder.
    var fileExtension: String {
        guard provider != .unsplash else { return "jpg" }
        let candidate = origin.url.pathExtension.lowercased()
        return ImageFile.extensions.contains(candidate) ? candidate : "jpg"
    }

    // MARK: - Decoding

    /// Reads the current shape, and falls back to the Unsplash-only shape the
    /// app persisted before it had more than one provider.
    ///
    /// The fallback is not cosmetic: `photo-index.json` is what lets a cached
    /// file still be credited, and entries that fail to decode are treated as
    /// un-creditable and evicted first. Dropping the migration would quietly
    /// throw away every photo an existing user already has.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard container.contains(.provider) else {
            self = try Photo(from: decoder).artwork
            return
        }

        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(Provider.self, forKey: .provider)
        origin = try container.decode(Origin.self, forKey: .origin)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        creatorURL = try container.decodeIfPresent(URL.self, forKey: .creatorURL)
        webURL = try container.decodeIfPresent(URL.self, forKey: .webURL)
        downloadLocation = try container.decodeIfPresent(String.self, forKey: .downloadLocation)
    }
}

/// The image types the app is willing to put on a desktop.
enum ImageFile {
    /// What `NSImage` reads and `setDesktopImageURL` accepts. HEIC is included
    /// because it is what a modern iPhone writes, and macOS ships HEIC
    /// wallpapers of its own.
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
