import CoreGraphics
import Foundation

// MARK: - Errors

enum WallhavenError: LocalizedError {
    case invalidAPIKey
    case rateLimited
    case noPhotosFound(Source)
    case unexpectedStatus(Int)
    case transport(any Error)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Wallhaven rejected the API key. Remove it in Settings — Wallhaven needs no key for the wallpapers this app uses."
        case .rateLimited:
            "Too many Wallhaven requests in the last minute. It clears within a minute."
        case .noPhotosFound(let source):
            "No wallpapers found for \(source.displayName)."
        case .unexpectedStatus(let code):
            "Wallhaven returned an unexpected response (HTTP \(code))."
        case .transport(let error):
            error.localizedDescription
        }
    }
}

// MARK: - Client

/// Wallhaven's search API.
///
/// Three things set it apart from the other two providers:
///
/// * **No key.** SFW wallpapers are served to anonymous callers, so a Wallhaven
///   source is usable the moment it is added — like a folder, and unlike
///   Unsplash and APOD. The app never asks for a key and never sends one.
/// * **One endpoint.** Tags, colours and ratios are all query parameters on
///   `/search`, which is why there is a single `wallhaven` source kind where
///   Unsplash has three: a tag is just `q=id:37`.
/// * **No resizing, and no size guarantee either.** Wallhaven serves the file
///   as it was uploaded, so `PhotoResolution` has nothing to act on — but a
///   1280×720 upload would be stretched across a 5K display. `atleast` is the
///   only lever there is, so every search carries one.
///
/// A change costs one request: `/search` answers with a whole page of 24 and
/// there is no download to report afterwards.
@Observable
final class WallhavenClient {
    private static let base = URL(string: "https://wallhaven.cc/api/v1")!

    /// SFW only, all three categories. Purity is not a setting on purpose:
    /// this app puts photos on a desktop other people can see.
    private static let categories = "111"
    private static let purity = "100"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Fetching

    /// Fetches wallpapers from `source`, none smaller than `atLeast`.
    ///
    /// `sorting=random` reshuffles server-side on every call — no seed is sent,
    /// so two calls a second apart return different pages.
    ///
    /// The minimum size is dropped and the search repeated once when it matched
    /// nothing, because a narrow query on a 6K display can have a real answer
    /// that simply is not big enough. That second request only ever happens for
    /// a search that would otherwise have failed outright.
    func randomArtworks(count: Int, from source: Source, atLeast: CGSize) async throws -> [Artwork] {
        var page: Page = try await search(source, atLeast: atLeast)
        if page.data.isEmpty {
            page = try await search(source, atLeast: nil)
        }

        let artworks = page.data.compactMap(\.artwork).prefix(max(1, count))
        guard !artworks.isEmpty else { throw WallhavenError.noPhotosFound(source) }
        return Array(artworks)
    }

    private func search(_ source: Source, atLeast: CGSize?) async throws -> Page {
        var items = [
            URLQueryItem(name: "categories", value: Self.categories),
            URLQueryItem(name: "purity", value: Self.purity),
            URLQueryItem(name: "sorting", value: "random"),
            URLQueryItem(name: "ratios", value: "landscape"),
        ]
        // An empty query is the whole site, which is what a bare "wallhaven"
        // source means. Sending `q=` would narrow nothing but is noise.
        if let query = source.value.nilIfEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let atLeast {
            items.append(URLQueryItem(
                name: "atleast",
                value: "\(Int(atLeast.width))x\(Int(atLeast.height))"
            ))
        }

        return try await get("/search", query: items)
    }

    // MARK: - Tags

    /// A tag source is added as `id:37`, which means nothing to the user.
    /// Resolved once, when the source is added — the same bargain
    /// `UnsplashClient.collectionTitle` makes for a collection ID.
    func tagName(for id: String) async throws -> String {
        struct Response: Decodable {
            struct Tag: Decodable { let name: String }
            let data: Tag
        }
        let response: Response = try await get("/tag/\(id)", query: [])
        return response.data.name
    }

    // MARK: - Model

    private struct Page: Decodable {
        let data: [Entry]
    }

    /// One wallpaper, as `/search` returns it.
    ///
    /// Internal rather than private so the mapping can be tested without the
    /// network, for the same reason `NASAClient.Entry` is.
    struct Entry: Decodable {
        let id: String
        /// The wallpaper's page on wallhaven.cc.
        let url: String
        /// The file itself, at the size it was uploaded.
        let path: String
        /// Where the uploader said the image came from — an ArtStation or
        /// Unsplash link, often enough. Empty for most wallpapers.
        let source: String?

        /// `nil` when the file URL will not parse; nothing else here can fail.
        var artwork: Artwork? {
            guard let file = URL(string: path) else { return nil }

            return Artwork(
                id: id,
                provider: .wallhaven,
                origin: .remote(file),
                // Wallhaven wallpapers are user uploads: a search answer names
                // no photographer and carries no caption. The ID is what the
                // site itself calls the file — `wallhaven-4olrgp.jpg` — so it
                // is the one thing a history row can be recognised by.
                title: id,
                creator: nil,
                // Not a profile page: the uploader credited an original, and
                // that is the nearest thing to an author this provider has.
                creatorURL: source?.nilIfEmpty.flatMap { URL(string: $0) },
                webURL: URL(string: url),
                downloadLocation: nil
            )
        }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(
            url: Self.base.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30

        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WallhavenError.transport(error)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WallhavenError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WallhavenError.unexpectedStatus(-1)
        }

        // Wallhaven reports `X-Ratelimit-Limit`/`-Remaining` in the same headers
        // Unsplash and NASA use, but its quota is 45 a *minute* rather than a
        // roll-over on the hour, which is the one thing `RateLimit` assumes.
        // A gauge built on it would name the wrong reset time to describe a
        // limit one request per change cannot reach, so none is kept.
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw WallhavenError.invalidAPIKey
        case 429:
            throw WallhavenError.rateLimited
        default:
            throw WallhavenError.unexpectedStatus(http.statusCode)
        }
    }
}
