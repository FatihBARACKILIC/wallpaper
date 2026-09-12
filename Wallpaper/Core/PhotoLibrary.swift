import Foundation

/// What the user has seen, and what they have decided about it: the last
/// wallpapers that went up, the ones they pinned to keep, and the ones they
/// never want to see again.
///
/// Deliberately not part of `AppSettings`. These lists grow with use rather
/// than with configuration, and a 50-entry history rewritten on every change
/// has no business sitting in the same blob as the interval and the sources.
/// They live in their own file beside `photo-index.json`, inside the folder the
/// uninstaller already removes.
///
/// Everything here is in `Artwork` terms — never a file path. A cached file can
/// be evicted at any time, so a remembered photo is re-resolved when it is
/// applied again: from disk if it is still there, downloaded again if it is
/// not. Only a photo from one of the user's own folders can be lost for good,
/// and only because the user deleted it.
@Observable
final class PhotoLibrary {
    /// One remembered photo, and when it was remembered — applied, pinned or
    /// blocked, depending on which list it is in.
    struct Entry: Codable, Hashable, Identifiable {
        var artwork: Artwork
        var date: Date

        /// `Artwork.id` is unique only within its provider, so the list key is
        /// `Artwork.key` rather than the ID.
        var id: String { artwork.key }
    }

    /// How far back the menu can walk. Long enough to find the photo that went
    /// past while the user was in a meeting, short enough that the file stays
    /// small and the list stays readable.
    static let historyLimit = 50

    /// Newest first — the wallpaper on screen is normally `history[0]`.
    private(set) var history: [Entry] = []
    /// Pinned photos, newest pin first. Never evicted from the cache.
    private(set) var favorites: [Entry] = []
    /// "Never show again", newest first.
    private(set) var blocked: [Entry] = []

    /// Asked once per candidate on every pick, so membership is kept as a set
    /// rather than scanned out of `blocked` each time.
    private(set) var blockedKeys: Set<String> = []
    private(set) var favoriteKeys: Set<String> = []

    private let fileURL: URL

    /// `directory` is the app's Application Support folder — the parent of the
    /// photo folder, so the library sits beside `photo-index.json` rather than
    /// among the photos, where the storage limit would count it and eviction
    /// would delete it.
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wallpaper", directoryHint: .isDirectory)

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appending(path: "library.json")
        load()
    }

    // MARK: - Asking

    func isFavorite(_ artwork: Artwork) -> Bool { favoriteKeys.contains(artwork.key) }
    func isBlocked(_ artwork: Artwork) -> Bool { blockedKeys.contains(artwork.key) }

    /// The photo one step further back than `cursor`, or `nil` at the end of
    /// the history. `cursor` is `nil` when what is on screen did not come from
    /// the history at all, so the first step back is then the newest entry.
    func entry(before cursor: Int?) -> (index: Int, entry: Entry)? {
        let index = (cursor ?? -1) + 1
        guard index < history.count else { return nil }
        return (index, history[index])
    }

    func index(of artwork: Artwork) -> Int? {
        history.firstIndex { $0.id == artwork.key }
    }

    // MARK: - Recording

    /// Remembers photos that have just gone up, newest first.
    ///
    /// A photo shown twice moves to the front rather than appearing twice: the
    /// list is "the last 50 wallpapers", and a cache fallback re-using the same
    /// few photos while the network is down would otherwise fill all 50 slots
    /// with one of them.
    func record(_ artworks: [Artwork]) {
        guard !artworks.isEmpty else { return }

        let now = Date()
        let fresh = artworks.map { Entry(artwork: $0, date: now) }
        let keys = Set(fresh.map(\.id))

        history.removeAll { keys.contains($0.id) }
        history.insert(contentsOf: fresh, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        save()
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        save()
    }

    // MARK: - Pinning

    /// Pins a photo: it is kept out of cache eviction and can be put back up at
    /// any time. Returns the state it ended in, for the menu's label.
    @discardableResult
    func toggleFavorite(_ artwork: Artwork) -> Bool {
        if isFavorite(artwork) {
            unfavorite(artwork)
            return false
        }
        favorite(artwork)
        return true
    }

    func favorite(_ artwork: Artwork) {
        guard !isFavorite(artwork) else { return }

        // Pinning something blocked earlier is the user changing their mind,
        // not a contradiction to be kept on file.
        blocked.removeAll { $0.id == artwork.key }
        blockedKeys.remove(artwork.key)

        favorites.insert(Entry(artwork: artwork, date: Date()), at: 0)
        favoriteKeys.insert(artwork.key)
        save()
    }

    func unfavorite(_ artwork: Artwork) {
        guard isFavorite(artwork) else { return }
        favorites.removeAll { $0.id == artwork.key }
        favoriteKeys.remove(artwork.key)
        save()
    }

    // MARK: - Blocking

    /// "Never show again". The photo also leaves the history and the pins — a
    /// blocked photo still offering a "Set again" button would be a lie.
    func block(_ artwork: Artwork) {
        guard !isBlocked(artwork) else { return }

        favorites.removeAll { $0.id == artwork.key }
        favoriteKeys.remove(artwork.key)
        history.removeAll { $0.id == artwork.key }

        blocked.insert(Entry(artwork: artwork, date: Date()), at: 0)
        blockedKeys.insert(artwork.key)
        save()
    }

    func unblock(_ artwork: Artwork) {
        guard isBlocked(artwork) else { return }
        blocked.removeAll { $0.id == artwork.key }
        blockedKeys.remove(artwork.key)
        save()
    }

    // MARK: - Persistence

    /// The three lists, in the shape they take on disk.
    ///
    /// Decoded field by field for the same reason `AppSettings` is: the
    /// synthesized decoder throws `keyNotFound` for a list an older build never
    /// wrote, and a throw here drops the whole file. A fourth list added one
    /// day must be read with `decodeIfPresent` too, or adding it would silently
    /// throw away every pin the user has.
    private struct Stored: Codable {
        var history: [Entry] = []
        var favorites: [Entry] = []
        var blocked: [Entry] = []

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            history = try container.decodeIfPresent([Entry].self, forKey: .history) ?? []
            favorites = try container.decodeIfPresent([Entry].self, forKey: .favorites) ?? []
            blocked = try container.decodeIfPresent([Entry].self, forKey: .blocked) ?? []
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }

        history = Array(stored.history.prefix(Self.historyLimit))
        favorites = stored.favorites
        blocked = stored.blocked
        favoriteKeys = Set(favorites.map(\.id))
        blockedKeys = Set(blocked.map(\.id))
    }

    private func save() {
        var stored = Stored()
        stored.history = history
        stored.favorites = favorites
        stored.blocked = blocked

        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
