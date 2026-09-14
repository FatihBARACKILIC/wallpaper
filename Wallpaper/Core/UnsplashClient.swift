import Foundation

// MARK: - Models

/// Unsplash's own JSON shape. It stops at the edge of the client: everything
/// past `randomArtworks` deals in `Artwork`.
nonisolated struct Photo: Codable, Hashable, Identifiable, Sendable {
    struct URLs: Codable, Hashable, Sendable {
        let raw: String
        let full: String
    }

    struct Links: Codable, Hashable, Sendable {
        let html: String
        /// Must be hit after a photo is used — required by the API guidelines.
        let downloadLocation: String

        enum CodingKeys: String, CodingKey {
            case html
            case downloadLocation = "download_location"
        }
    }

    struct User: Codable, Hashable, Sendable {
        struct Links: Codable, Hashable, Sendable { let html: String }

        let name: String
        let username: String
        let links: Links
    }

    let id: String
    let width: Int
    let height: Int
    let description: String?
    let altDescription: String?
    /// The photo's dominant colour, `#0c2a3a`. Optional because it is absent
    /// from the shape this type used to be persisted in, which still has to
    /// decode — see `Artwork.init(from:)`.
    let color: String?
    let urls: URLs
    let links: Links
    let user: User

    enum CodingKeys: String, CodingKey {
        case id, width, height, description, color, urls, links, user
        case altDescription = "alt_description"
    }

    /// Attribution links must carry UTM parameters — see `UnsplashAttribution`.
    var webURL: URL? { UnsplashAttribution.link(links.html) }

    var photographerURL: URL? { UnsplashAttribution.link(user.links.html) }

    /// Short human description used in the cached filename, e.g. "misty mountain lake".
    var caption: String? {
        let text = description ?? altDescription
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// `raw` carries the CDN's resizing parameters; `full` is the fallback for
    /// the rare photo whose `raw` will not parse.
    var artwork: Artwork {
        let remote = URL(string: urls.raw) ?? URL(string: urls.full)
        return Artwork(
            id: id,
            provider: .unsplash,
            origin: .remote(remote ?? URL(fileURLWithPath: "/dev/null")),
            title: caption,
            creator: user.name,
            creatorURL: photographerURL,
            webURL: webURL,
            downloadLocation: links.downloadLocation,
            // Sent with every search result, so a batch can be ranked against
            // the sky without downloading any of it.
            lightness: color.flatMap(ImageBrightness.lightness(ofHex:))
        )
    }
}

/// What the last API response reported about the hourly quota. Persisted so the
/// menu bar gauge never has to spend a request to refresh itself.
struct RateLimit: Codable, Hashable, Sendable {
    var limit: Int
    var remaining: Int
    var observedAt: Date

    /// Both Unsplash and NASA report the same two headers, and both roll the
    /// quota over on the hour.
    init?(_ response: HTTPURLResponse) {
        guard
            let limit = response.value(forHTTPHeaderField: "X-Ratelimit-Limit").flatMap(Int.init),
            let remaining = response.value(forHTTPHeaderField: "X-Ratelimit-Remaining").flatMap(Int.init)
        else { return nil }

        self.limit = limit
        self.remaining = remaining
        self.observedAt = Date()
    }

    init(limit: Int, remaining: Int, observedAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.observedAt = observedAt
    }

    /// Quotas roll over on the hour.
    var resetsAt: Date {
        Calendar.current.nextDate(
            after: observedAt,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? observedAt.addingTimeInterval(3600)
    }

    var isStale: Bool { Date() >= resetsAt }
}

// MARK: - Errors

enum UnsplashError: LocalizedError {
    case missingAccessKey
    case invalidAccessKey
    case rateLimited(resetsAt: Date?)
    case noPhotosFound(Source)
    case unexpectedStatus(Int)
    case transport(any Error)

    var errorDescription: String? {
        switch self {
        case .missingAccessKey:
            "No Unsplash Access Key set. Add one in Settings."
        case .invalidAccessKey:
            "Unsplash rejected this key. Make sure you copied the Access Key, not the Secret Key."
        case .rateLimited:
            "Hourly Unsplash request limit reached. It resets at the top of the hour."
        case .noPhotosFound(let source):
            "No photos found for \(source.displayName)."
        case .unexpectedStatus(let code):
            "Unsplash returned an unexpected response (HTTP \(code))."
        case .transport(let error):
            error.localizedDescription
        }
    }
}

// MARK: - Client

@Observable
final class UnsplashClient {
    private static let base = URL(string: "https://api.unsplash.com")!
    private static let topicIDCacheKey = "topicIDCache"

    /// Last observed quota, surfaced in the menu bar.
    private(set) var rateLimit: RateLimit?

    private let session: URLSession
    private let defaults: UserDefaults
    private let accessKeyProvider: () -> String?

    /// Topic slugs resolved to IDs. `/photos/random` filters by topic ID, so a
    /// slug is resolved once and remembered.
    private var topicIDs: [String: String]

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        accessKeyProvider: @escaping () -> String? = { Keychain.unsplashAccessKey.read() }
    ) {
        self.session = session
        self.defaults = defaults
        self.accessKeyProvider = accessKeyProvider
        self.topicIDs = defaults.dictionary(forKey: Self.topicIDCacheKey) as? [String: String] ?? [:]
    }

    /// Fetches `count` random photos from `source`.
    func randomArtworks(count: Int, from source: Source) async throws -> [Artwork] {
        var items = [
            URLQueryItem(name: "count", value: String(max(1, min(count, 30)))),
            URLQueryItem(name: "orientation", value: "landscape"),
            URLQueryItem(name: "content_filter", value: "high"),
        ]

        switch source.kind {
        case .topic:
            items.append(URLQueryItem(name: "topics", value: try await topicID(for: source.value)))
        case .collection:
            items.append(URLQueryItem(name: "collections", value: source.value))
        case .search:
            items.append(URLQueryItem(name: "query", value: source.value))
        case .apod, .wallhaven, .folder:
            // Routed elsewhere; the client is never handed one of these.
            throw UnsplashError.noPhotosFound(source)
        }

        let photos: [Photo] = try await get("/photos/random", query: items)
        guard !photos.isEmpty else { throw UnsplashError.noPhotosFound(source) }
        return photos.map(\.artwork)
    }

    /// Required by the Unsplash API guidelines once a photo is actually used.
    /// Failure here must never block setting the wallpaper.
    func reportDownload(for artwork: Artwork) async {
        guard artwork.provider == .unsplash,
              let location = artwork.downloadLocation,
              let url = URL(string: location)
        else { return }
        _ = try? await send(request(for: url))
    }

    // MARK: - Collections

    /// A collection is added by ID, which means nothing to the user. Resolve
    /// its title once, when it is added.
    func collectionTitle(for id: String) async throws -> String {
        struct Collection: Decodable { let title: String }
        let collection: Collection = try await get("/collections/\(id)", query: [])
        return collection.title
    }

    // MARK: - Topics

    private func topicID(for slug: String) async throws -> String {
        if let cached = topicIDs[slug] { return cached }

        struct Topic: Decodable { let id: String }
        let topic: Topic = try await get("/topics/\(slug)", query: [])

        topicIDs[slug] = topic.id
        defaults.set(topicIDs, forKey: Self.topicIDCacheKey)
        return topic.id
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(
            url: Self.base.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        let data = try await send(request(for: components.url!))

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw UnsplashError.transport(error)
        }
    }

    private func request(for url: URL) throws -> URLRequest {
        guard let key = accessKeyProvider()?.nilIfEmpty else { throw UnsplashError.missingAccessKey }

        var request = URLRequest(url: url)
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        request.timeoutInterval = 30
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UnsplashError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UnsplashError.unexpectedStatus(-1)
        }

        if let observed = RateLimit(http) { rateLimit = observed }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw UnsplashError.invalidAccessKey
        case 403:
            // Unsplash uses 403 for quota exhaustion as well as forbidden.
            if rateLimit?.remaining == 0 {
                throw UnsplashError.rateLimited(resetsAt: rateLimit?.resetsAt)
            }
            throw UnsplashError.invalidAccessKey
        case 429:
            throw UnsplashError.rateLimited(resetsAt: rateLimit?.resetsAt)
        default:
            throw UnsplashError.unexpectedStatus(http.statusCode)
        }
    }
}

// MARK: - Helpers

extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
