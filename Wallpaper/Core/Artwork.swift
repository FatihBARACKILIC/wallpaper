import Foundation

/// One photo, in the form the rest of the app stores, credits and applies.
///
/// The providers speak different dialects — Unsplash answers with a deep JSON
/// object, NASA APOD with a flat one, a local folder with nothing at all — so
/// each maps into this before anything else sees it. Everything persisted
/// (`photo-index.json`, `currentWallpapers`) is in these terms.
/// `nonisolated` because this is data, not state. The app defaults every type
/// to the main actor, which is right for the objects that hold the app together
/// and wrong for the value it passes between them: a folder scan, a brightness
/// measurement and a download all describe photos from a background executor.
nonisolated struct Artwork: Codable, Hashable, Identifiable, Sendable {
    enum Provider: String, Codable, Sendable {
        case unsplash
        case apod
        case wallhaven
        case local

        var displayName: String {
            switch self {
            case .unsplash: "Unsplash"
            case .apod: "NASA APOD"
            case .wallhaven: "Wallhaven"
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

    /// Unique within its provider: an Unsplash or Wallhaven ID, an APOD date,
    /// a file path.
    let id: String
    let provider: Provider
    let origin: Origin
    /// Caption, APOD title, or the file's own name. A Wallhaven upload has
    /// none of those, so it carries its ID — which is what the site names the
    /// file after.
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
    /// How light or dark this photo is, 0…1 on the CIE L\* scale, or `nil` when
    /// nobody has worked it out yet.
    ///
    /// Filled in from the dominant colours Unsplash and Wallhaven send with
    /// every search result — which is what lets a whole batch be ranked against
    /// the sky before a single byte is downloaded — and measured from the file
    /// for the providers that send nothing. See `ImageBrightness`.
    let lightness: Double?

    /// Identity across providers, for the lists that remember photos.
    ///
    /// `id` alone will not do: it is unique only *within* a provider, and the
    /// namespaces overlap in shape — an APOD entry is a date, a folder photo is
    /// a path, and an Unsplash and a Wallhaven ID are the same short string of
    /// letters. Two photos are the same photo when both parts match.
    var key: String { Self.key(provider: provider, id: id) }

    /// The same key for code that has the parts but not the photo: a folder
    /// draw filters thousands of files against the block list, and building an
    /// `Artwork` for each one to ask its key is the work that filter exists to
    /// avoid. Kept here so the two spellings cannot drift apart.
    static func key(provider: Provider, id: String) -> String {
        "\(provider.rawValue):\(id)"
    }

    /// Where this photo came from, ready to open.
    ///
    /// An Unsplash link is rebuilt rather than used as stored: `webURL` was
    /// built with whatever application name was registered when the photo was
    /// fetched, and the guidelines ask for the one registered *now* — a photo
    /// remembered in the history can be older than the current setting.
    /// `UnsplashAttribution.link` strips the old parameters before adding the
    /// current ones, so re-applying it is safe.
    var sourceURL: URL? {
        guard let webURL else { return nil }
        guard provider == .unsplash else { return webURL }
        return UnsplashAttribution.link(webURL.absoluteString) ?? webURL
    }

    /// One line naming this photo, for a list row. Falls back through what the
    /// providers actually give: an Unsplash caption, an APOD title or the
    /// Wallhaven ID, then the photographer, then the provider itself for a
    /// public-domain NASA image with no title at all.
    var shortLabel: String {
        title ?? creator ?? provider.displayName
    }

    init(
        id: String,
        provider: Provider,
        origin: Origin,
        title: String? = nil,
        creator: String? = nil,
        creatorURL: URL? = nil,
        webURL: URL? = nil,
        downloadLocation: String? = nil,
        lightness: Double? = nil
    ) {
        self.id = id
        self.provider = provider
        self.origin = origin
        self.title = title
        self.creator = creator
        self.creatorURL = creatorURL
        self.webURL = webURL
        self.downloadLocation = downloadLocation
        self.lightness = lightness
    }

    /// The same photo with its brightness filled in — `Artwork` is otherwise
    /// immutable, and measuring a file is the one thing that can only happen
    /// after the photo already exists.
    func withLightness(_ lightness: Double?) -> Artwork {
        Artwork(
            id: id,
            provider: provider,
            origin: origin,
            title: title,
            creator: creator,
            creatorURL: creatorURL,
            webURL: webURL,
            downloadLocation: downloadLocation,
            lightness: lightness ?? self.lightness
        )
    }

    /// A URL for the actual bytes, or `nil` for a file already on disk.
    ///
    /// Only Unsplash resizes server-side: its CDN takes `w`/`h` and returns a
    /// screen-sized JPEG instead of a 50 MB original. APOD and Wallhaven serve
    /// fixed files, so the resolution setting has nothing to act on there —
    /// Wallhaven is kept large by asking `atleast` of the search instead.
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
    /// explicitly; APOD and Wallhaven serve whatever they have, and a PNG saved
    /// as `.jpg` would be a lie to every other app that reads the folder.
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
        lightness = try container.decodeIfPresent(Double.self, forKey: .lightness)
    }
}

/// The image types the app is willing to put on a desktop.
nonisolated enum ImageFile {
    /// What `NSImage` reads and `setDesktopImageURL` accepts. HEIC is included
    /// because it is what a modern iPhone writes, and macOS ships HEIC
    /// wallpapers of its own.
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
