import Foundation

// MARK: - Errors

enum NASAError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(resetsAt: Date?)
    case noPhotosFound
    case unexpectedStatus(Int)
    case transport(any Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No NASA API key set. Add one in Settings to use the APOD source."
        case .invalidAPIKey:
            "NASA rejected this API key. Check it in Settings."
        case .rateLimited:
            "Hourly NASA request limit reached. It resets at the top of the hour."
        case .noPhotosFound:
            "NASA returned no usable pictures — the ones it picked were videos."
        case .unexpectedStatus(let code):
            "NASA returned an unexpected response (HTTP \(code))."
        case .transport(let error):
            error.localizedDescription
        }
    }
}

// MARK: - Client

/// NASA's Astronomy Picture of the Day.
///
/// Like Unsplash, `count=N` returns N random entries in a *single* request, so
/// a change still costs one request no matter how many screens are dressed —
/// and unlike Unsplash there is no download to report afterwards.
///
/// Two things the API does that Unsplash does not: some days are videos rather
/// than images, and `hdurl` is not always present. Both are handled here so
/// nothing downstream has to know.
@Observable
final class NASAClient {
    private static let endpoint = URL(string: "https://api.nasa.gov/planetary/apod")!

    /// Last observed quota, surfaced in the menu bar alongside Unsplash's.
    private(set) var rateLimit: RateLimit?

    private let session: URLSession
    private let apiKeyProvider: () -> String?

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping () -> String? = { Keychain.nasaAPIKey.read() }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    // MARK: - Fetching

    /// Fetches `count` random pictures of the day.
    ///
    /// Asks for a few more than needed because any of them can turn out to be a
    /// video: over-asking costs nothing (it is the same single request) and
    /// saves a second round trip on the days NASA picked a film.
    func randomArtworks(count: Int) async throws -> [Artwork] {
        let requested = min(100, max(1, count) + 5)
        let entries: [Entry] = try await get([
            URLQueryItem(name: "count", value: String(requested)),
            URLQueryItem(name: "thumbs", value: "false"),
        ])

        let artworks = entries.compactMap(\.artwork).prefix(max(1, count))
        guard !artworks.isEmpty else { throw NASAError.noPhotosFound }
        return Array(artworks)
    }

    /// Confirms a key works before it is stored, so a bad paste is caught at the
    /// moment it happens rather than at the next wallpaper change.
    func validate(key: String) async throws {
        let _: [Entry] = try await get([URLQueryItem(name: "count", value: "1")], overridingKey: key)
    }

    // MARK: - Model

    /// One day's entry. Everything optional here really is optional in the live
    /// API — a video day carries no `hdurl`, and only copyrighted pictures
    /// carry `copyright`; a NASA-made image simply omits it and is public domain.
    ///
    /// Internal rather than private so the mapping — which silently drops the
    /// days NASA picked a film — can be tested without the network.
    struct Entry: Decodable {
        let date: String
        let title: String
        let mediaType: String
        let url: String
        let hdurl: String?
        let copyright: String?

        enum CodingKeys: String, CodingKey {
            case date, title, url, hdurl, copyright
            case mediaType = "media_type"
        }

        /// `nil` for anything that is not a still image.
        var artwork: Artwork? {
            guard mediaType == "image" else { return nil }

            // `hdurl` is the full-size file; APOD has no resizing parameters, so
            // taking the largest on offer is the only lever there is.
            guard let best = URL(string: hdurl ?? url) else { return nil }

            return Artwork(
                id: "apod-\(date)",
                provider: .apod,
                origin: .remote(best),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                creator: copyright?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                creatorURL: nil,
                webURL: Self.pageURL(for: date),
                downloadLocation: nil
            )
        }

        /// APOD archives each day at `apYYMMDD.html`.
        static func pageURL(for date: String) -> URL? {
            let digits = date.split(separator: "-")
            guard digits.count == 3, digits[0].count == 4 else { return nil }
            return URL(string: "https://apod.nasa.gov/apod/ap\(digits[0].suffix(2))\(digits[1])\(digits[2]).html")
        }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ query: [URLQueryItem], overridingKey: String? = nil) async throws -> T {
        guard let key = (overridingKey ?? apiKeyProvider())?.nilIfEmpty else {
            throw NASAError.missingAPIKey
        }

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = query + [URLQueryItem(name: "api_key", value: key)]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30

        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NASAError.transport(error)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NASAError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NASAError.unexpectedStatus(-1)
        }

        if let observed = RateLimit(http) { rateLimit = observed }

        switch http.statusCode {
        case 200..<300:
            return data
        case 403:
            // api.nasa.gov answers 403 for a bad key and 429 for an exhausted
            // quota, so unlike Unsplash the two never have to be told apart.
            throw NASAError.invalidAPIKey
        case 429:
            throw NASAError.rateLimited(resetsAt: rateLimit?.resetsAt)
        default:
            throw NASAError.unexpectedStatus(http.statusCode)
        }
    }
}
