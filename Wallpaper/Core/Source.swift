import Foundation

/// One place photos can come from. The user may add several; each wallpaper
/// change picks one at random.
struct Source: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case topic
        case collection
        case search
        /// NASA's Astronomy Picture of the Day.
        case apod
        /// A folder of the user's own photos.
        case folder

        var displayName: String {
            switch self {
            case .topic: "Topic"
            case .collection: "Collection"
            case .search: "Search"
            case .apod: "NASA"
            case .folder: "Folder"
            }
        }

        /// Single-letter tag so the kinds are told apart at a glance.
        var prefix: String {
            switch self {
            case .topic: "t"
            case .collection: "c"
            case .search: "s"
            case .apod: "n"
            case .folder: "f"
            }
        }

        /// Which provider answers for this kind, and therefore which key — if
        /// any — has to be in the keychain before it can be used.
        var provider: Artwork.Provider {
            switch self {
            case .topic, .collection, .search: .unsplash
            case .apod: .apod
            case .folder: .local
            }
        }
    }

    /// The single value `apod` sources carry, so two of them compare equal and
    /// the list cannot collect duplicates.
    static let apodValue = "apod"

    static let apod = Source(kind: .apod, value: apodValue, title: "Astronomy Picture of the Day")

    static func folder(at url: URL) -> Source {
        Source(
            kind: .folder,
            value: url.standardizedFileURL.path,
            title: url.standardizedFileURL.lastPathComponent
        )
    }

    var id = UUID()
    var kind: Kind
    /// Topic slug, collection ID, search query, `apod`, or a folder path.
    var value: String
    /// Human name. Collections are identified by a numeric ID, which tells the
    /// user nothing on its own; a folder shows its own name rather than a path
    /// too long for the row.
    var title: String?

    /// Where a folder source points. Meaningless for every other kind.
    var folderURL: URL { URL(fileURLWithPath: value) }

    /// What the user reads: `c/Wallpapers`, `t/nature`, `f/Iceland 2025`.
    var shortLabel: String {
        "\(kind.prefix)/\(title ?? value)"
    }

    var displayName: String {
        switch kind {
        case .apod: "NASA Astronomy Picture of the Day"
        case .folder: "Folder: \(title ?? value)"
        default: "\(kind.displayName): \(title ?? value)"
        }
    }

    /// Only a collection is unreadable without a lookup; a slug, a query and a
    /// folder name already say what they are.
    var needsTitle: Bool {
        kind == .collection && title == nil
    }

    /// The page this source came from, for the "open" button on its row.
    var webURL: URL? {
        switch kind {
        case .topic: UnsplashAttribution.link("https://unsplash.com/t/\(value)")
        case .collection: UnsplashAttribution.link("https://unsplash.com/collections/\(value)")
        case .search:
            value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                .flatMap { UnsplashAttribution.link("https://unsplash.com/s/photos/\($0)") }
        case .apod: URL(string: "https://apod.nasa.gov/apod/astropix.html")
        case .folder: folderURL
        }
    }
}

extension Source {
    /// Accepts a pasted URL, a folder path, or plain text.
    ///
    /// Recognised:
    ///   unsplash.com/t/nature            -> topic "nature"
    ///   unsplash.com/topics/nature       -> topic "nature"
    ///   unsplash.com/collections/1234/x  -> collection "1234"
    ///   unsplash.com/s/photos/mountains  -> search "mountains"
    ///   apod.nasa.gov/…                  -> NASA APOD
    ///   /Users/me/Pictures/Iceland       -> that folder
    ///
    /// Anything else is treated as a search query.
    init?(input rawInput: String) {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if Self.namesAPOD(input) {
            self = .apod
            return
        }

        if let folder = Self.parseFolder(input) {
            self = folder
            return
        }

        guard let parsed = Self.parseUnsplashURL(input) else {
            self.init(kind: .search, value: input)
            return
        }
        self = parsed
    }

    /// Only the exact names, so a search for "apod photography" stays a search.
    private static func namesAPOD(_ input: String) -> Bool {
        let normalised = input.lowercased()
        if ["apod", "nasa apod", "nasa", "astronomy picture of the day"].contains(normalised) {
            return true
        }

        let candidate = input.contains("://") ? input : "https://\(input)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else { return false }
        return host == "apod.nasa.gov" || host.hasSuffix(".apod.nasa.gov")
    }

    /// A path or `file://` URL that really is a directory on this Mac. Checking
    /// the disk rather than the spelling keeps a search for "winter/snow" from
    /// being mistaken for a folder.
    private static func parseFolder(_ input: String) -> Source? {
        let path: String
        if input.hasPrefix("file://") {
            guard let url = URL(string: input), url.isFileURL else { return nil }
            path = url.path
        } else if input.hasPrefix("/") || input.hasPrefix("~") {
            path = (input as NSString).expandingTildeInPath
        } else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        return .folder(at: URL(fileURLWithPath: path))
    }

    private static func parseUnsplashURL(_ input: String) -> Source? {
        // Tolerate a pasted URL without a scheme ("unsplash.com/t/nature").
        let candidate = input.contains("://") ? input : "https://\(input)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              host == "unsplash.com" || host.hasSuffix(".unsplash.com")
        else { return nil }

        let path = components.path.split(separator: "/").map(String.init)

        switch path.first {
        case "t", "topics":
            guard let slug = path.dropFirst().first else { return nil }
            return Source(kind: .topic, value: slug)

        case "collections":
            // /collections/<id>/<slug> and /collections/<id> both carry the ID
            // second. Curated collections use /collections/curated/<id>.
            let rest = path.dropFirst()
            guard let first = rest.first else { return nil }
            if first == "curated" || first == "featured" {
                guard let id = rest.dropFirst().first else { return nil }
                return Source(kind: .collection, value: id)
            }
            return Source(kind: .collection, value: first)

        case "s":
            // /s/photos/<query>
            guard let query = path.dropFirst(2).first,
                  let decoded = query.removingPercentEncoding
            else { return nil }
            return Source(kind: .search, value: decoded.replacingOccurrences(of: "-", with: " "))

        default:
            // A search URL can also arrive as /search/photos?query=x
            if let query = components.queryItems?.first(where: { $0.name == "query" })?.value,
               !query.isEmpty {
                return Source(kind: .search, value: query)
            }
            return nil
        }
    }
}
