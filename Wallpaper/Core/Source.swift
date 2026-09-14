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
        /// A Wallhaven search. Tags, colours and ratios are all query
        /// parameters on the one endpoint Wallhaven has, so a tag is this kind
        /// too — with `id:37` as its value.
        case wallhaven
        /// A folder of the user's own photos.
        case folder

        var displayName: String {
            switch self {
            case .topic: "Topic"
            case .collection: "Collection"
            case .search: "Search"
            case .apod: "NASA"
            case .wallhaven: "Wallhaven"
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
            case .wallhaven: "w"
            case .folder: "f"
            }
        }

        /// Which provider answers for this kind, and therefore which key — if
        /// any — has to be in the keychain before it can be used.
        var provider: Artwork.Provider {
            switch self {
            case .topic, .collection, .search: .unsplash
            case .apod: .apod
            case .wallhaven: .wallhaven
            case .folder: .local
            }
        }
    }

    /// The single value `apod` sources carry, so two of them compare equal and
    /// the list cannot collect duplicates.
    static let apodValue = "apod"

    static let apod = Source(kind: .apod, value: apodValue, title: "Astronomy Picture of the Day")

    /// A Wallhaven search. An empty query is the whole site, which is what
    /// `wallhaven` on its own means; it needs a title because `w/` with nothing
    /// after it reads as a mistake.
    static func wallhaven(query: String = "") -> Source {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Source(
            kind: .wallhaven,
            value: trimmed,
            title: trimmed.isEmpty ? "Everything" : nil
        )
    }

    static func folder(at url: URL) -> Source {
        Source(
            kind: .folder,
            value: url.standardizedFileURL.path,
            title: url.standardizedFileURL.lastPathComponent
        )
    }

    var id = UUID()
    var kind: Kind
    /// Topic slug, collection ID, search query, `apod`, a Wallhaven query, or
    /// a folder path.
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
        case .wallhaven: "Wallhaven: \(title ?? value)"
        case .folder: "Folder: \(title ?? value)"
        default: "\(kind.displayName): \(title ?? value)"
        }
    }

    /// Only an ID is unreadable without a lookup — an Unsplash collection, or
    /// a Wallhaven tag, which the site writes as `id:37`. A slug, a query and a
    /// folder name already say what they are.
    var needsTitle: Bool {
        guard title == nil else { return false }
        return kind == .collection || (kind == .wallhaven && wallhavenTagID != nil)
    }

    /// The numeric tag this Wallhaven source searches for, if it searches for
    /// one rather than for words.
    var wallhavenTagID: String? {
        guard kind == .wallhaven, value.hasPrefix("id:") else { return nil }
        let id = String(value.dropFirst(3))
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil
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
        case .wallhaven:
            value.isEmpty
                ? URL(string: "https://wallhaven.cc/")
                : value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                    .flatMap { URL(string: "https://wallhaven.cc/search?q=\($0)") }
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
    ///   wallhaven                        -> all of Wallhaven
    ///   wallhaven mountains              -> Wallhaven search "mountains"
    ///   wallhaven.cc/search?q=mountains  -> Wallhaven search "mountains"
    ///   wallhaven.cc/tag/37              -> Wallhaven tag "id:37"
    ///   /Users/me/Pictures/Iceland       -> that folder
    ///
    /// Anything else is treated as an Unsplash search query — the fallback a
    /// bare word has always had, which is why Wallhaven has to be named.
    init?(input rawInput: String) {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if Self.namesAPOD(input) {
            self = .apod
            return
        }

        if let wallhaven = Self.parseWallhaven(input) {
            self = wallhaven
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

    /// A Wallhaven source, named or pasted.
    ///
    /// Naming it is not a convenience: plain text falls through to an Unsplash
    /// search, so "wallhaven mountains" is the only way to type a Wallhaven
    /// query rather than paste one. It shadows an Unsplash search for the word
    /// "wallhaven", which is the same trade "nasa" already makes.
    private static func parseWallhaven(_ input: String) -> Source? {
        let normalised = input.lowercased()
        if normalised == "wallhaven" || normalised == "wallhaven.cc" {
            return .wallhaven()
        }
        if normalised.hasPrefix("wallhaven ") {
            return .wallhaven(query: String(input.dropFirst("wallhaven ".count)))
        }

        let candidate = input.contains("://") ? input : "https://\(input)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              host == "wallhaven.cc" || host.hasSuffix(".wallhaven.cc") || host == "whvn.cc"
        else { return nil }

        let path = components.path.split(separator: "/").map(String.init)

        // /tag/<id> is a search for that tag; the API spells it `id:<n>`.
        if path.first == "tag", let id = path.dropFirst().first, id.allSatisfy(\.isNumber) {
            return Source(kind: .wallhaven, value: "id:\(id)")
        }

        if let query = components.queryItems?.first(where: { $0.name == "q" })?.value?.nilIfEmpty {
            return .wallhaven(query: query)
        }

        // /latest, /hot, /toplist, a single wallpaper's page — none of them is a
        // query, so the honest reading is "Wallhaven, all of it".
        return .wallhaven()
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
