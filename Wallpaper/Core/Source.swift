import Foundation

/// One place photos can come from. The user may add several; each wallpaper
/// change picks one at random.
struct Source: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case topic
        case collection
        case search

        var displayName: String {
            switch self {
            case .topic: "Topic"
            case .collection: "Collection"
            case .search: "Search"
            }
        }

        /// Single-letter tag so the three kinds are told apart at a glance.
        var prefix: String {
            switch self {
            case .topic: "t"
            case .collection: "c"
            case .search: "s"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// Topic slug, collection ID, or search query.
    var value: String
    /// Human name fetched from Unsplash. Collections are identified by a
    /// numeric ID, which tells the user nothing on its own.
    var title: String?

    /// What the user reads: `c/Wallpapers`, `t/nature`, `s/misty forest`.
    var shortLabel: String {
        "\(kind.prefix)/\(title ?? value)"
    }

    var displayName: String {
        "\(kind.displayName): \(title ?? value)"
    }

    /// Only a collection is unreadable without a lookup; a slug and a query
    /// already say what they are.
    var needsTitle: Bool {
        kind == .collection && title == nil
    }

    /// The page this source came from, for the "open in Unsplash" menu item.
    var webURL: URL? {
        switch kind {
        case .topic: UnsplashAttribution.link("https://unsplash.com/t/\(value)")
        case .collection: UnsplashAttribution.link("https://unsplash.com/collections/\(value)")
        case .search:
            value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                .flatMap { UnsplashAttribution.link("https://unsplash.com/s/photos/\($0)") }
        }
    }
}

extension Source {
    /// Accepts either a pasted Unsplash URL or plain text.
    ///
    /// Recognised URLs:
    ///   unsplash.com/t/nature            -> topic "nature"
    ///   unsplash.com/topics/nature       -> topic "nature"
    ///   unsplash.com/collections/1234/x  -> collection "1234"
    ///   unsplash.com/s/photos/mountains  -> search "mountains"
    ///
    /// Anything else is treated as a search query.
    init?(input rawInput: String) {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        guard let parsed = Self.parseUnsplashURL(input) else {
            self.init(kind: .search, value: input)
            return
        }
        self = parsed
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
