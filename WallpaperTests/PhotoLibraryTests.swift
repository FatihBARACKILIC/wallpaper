import Foundation
import Testing
@testable import Wallpaper

/// The history, the pins and the block list. All pure bookkeeping, which is
/// exactly the part worth testing: the manager only ever asks these lists what
/// they hold.
@Suite("Photo library")
struct PhotoLibraryTests {

    private func makeLibrary() -> (library: PhotoLibrary, folder: TemporaryFolder) {
        let folder = TemporaryFolder()
        return (PhotoLibrary(directory: folder.url), folder)
    }

    // MARK: - History

    @Test("The newest wallpaper is first")
    func newestFirst() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        library.record([makeArtwork(id: "one")])
        library.record([makeArtwork(id: "two")])

        #expect(library.history.map(\.artwork.id) == ["two", "one"])
    }

    @Test("A change in per-screen mode records every photo it put up")
    func recordsWholeBatch() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        library.record([makeArtwork(id: "left"), makeArtwork(id: "right")])
        #expect(library.history.count == 2)
    }

    @Test("The history stops at 50")
    func capped() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        for index in 0..<60 {
            library.record([makeArtwork(id: "photo-\(index)")])
        }

        #expect(library.history.count == PhotoLibrary.historyLimit)
        // The oldest go, not the newest.
        #expect(library.history.first?.artwork.id == "photo-59")
        #expect(library.history.last?.artwork.id == "photo-10")
    }

    @Test("A photo shown twice moves to the front instead of appearing twice")
    func deduplicates() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        // What the cache fallback does while the network is down: the same few
        // photos, over and over. Keeping every showing would fill all 50 slots
        // with one photo.
        library.record([makeArtwork(id: "a")])
        library.record([makeArtwork(id: "b")])
        library.record([makeArtwork(id: "a")])

        #expect(library.history.map(\.artwork.id) == ["a", "b"])
    }

    @Test("Two providers can use the same ID without colliding")
    func providerScopedIdentity() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        // An APOD entry is identified by a date and a folder photo by a path,
        // so `id` alone is not an identity — `key` carries the provider.
        let apod = makeAPODArtwork(date: "2020-06-17")!
        let local = makeLocalArtwork(at: URL(fileURLWithPath: "/Users/me/2020-06-17"))

        library.record([apod, local])
        #expect(library.history.count == 2)

        library.block(apod)
        #expect(library.isBlocked(apod))
        #expect(!library.isBlocked(local))
    }

    @Test("Clearing the history keeps the pins")
    func clearingKeepsPins() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        let artwork = makeArtwork(id: "keep")
        library.record([artwork])
        library.favorite(artwork)
        library.clearHistory()

        #expect(library.history.isEmpty)
        #expect(library.isFavorite(artwork))
    }

    // MARK: - Walking back

    @Test("Stepping back walks the history instead of bouncing")
    func walksBack() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        library.record([makeArtwork(id: "oldest")])
        library.record([makeArtwork(id: "middle")])
        library.record([makeArtwork(id: "newest")])

        // The wallpaper on screen is the newest, at cursor 0.
        let first = library.entry(before: 0)
        #expect(first?.entry.artwork.id == "middle")

        let second = library.entry(before: first?.index)
        #expect(second?.entry.artwork.id == "oldest")

        #expect(library.entry(before: second?.index) == nil)
    }

    @Test("A wallpaper that did not come from the history steps back to the newest")
    func stepsBackFromNowhere() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        library.record([makeArtwork(id: "newest")])

        // What a pinned photo picked out of Settings leaves behind: nothing on
        // screen came from the history, so the first step back is its top.
        #expect(library.entry(before: nil)?.entry.artwork.id == "newest")
    }

    @Test("An empty history has nowhere to go back to")
    func nothingToGoBackTo() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        #expect(library.entry(before: nil) == nil)
    }

    // MARK: - Pins and blocks

    @Test("Pinning and unpinning is one button")
    func togglesPin() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        let artwork = makeArtwork()
        #expect(library.toggleFavorite(artwork) == true)
        #expect(library.favorites.count == 1)
        #expect(library.toggleFavorite(artwork) == false)
        #expect(library.favorites.isEmpty)
    }

    @Test("Blocking a photo takes it out of the history and the pins")
    func blockingClearsElsewhere() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        let artwork = makeArtwork(id: "rejected")
        library.record([artwork])
        library.favorite(artwork)

        library.block(artwork)

        // A blocked photo still offering a "Set again" button would be a lie.
        #expect(library.history.isEmpty)
        #expect(library.favorites.isEmpty)
        #expect(library.blockedKeys == [artwork.key])
    }

    @Test("Pinning something blocked earlier unblocks it")
    func pinningUnblocks() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        let artwork = makeArtwork()
        library.block(artwork)
        library.favorite(artwork)

        #expect(!library.isBlocked(artwork))
        #expect(library.isFavorite(artwork))
    }

    @Test("Blocking twice is not two entries")
    func blockingIsIdempotent() {
        let (library, folder) = makeLibrary()
        defer { folder.cleanUp() }

        let artwork = makeArtwork()
        library.block(artwork)
        library.block(artwork)

        #expect(library.blocked.count == 1)
    }

    // MARK: - Persistence

    @Test("The lists survive a quit")
    func persists() {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        let pinned = makeArtwork(id: "pinned")
        let blocked = makeArtwork(id: "blocked")

        let first = PhotoLibrary(directory: folder.url)
        first.record([makeArtwork(id: "shown")])
        first.favorite(pinned)
        first.block(blocked)

        let second = PhotoLibrary(directory: folder.url)
        #expect(second.history.map(\.artwork.id) == ["shown"])
        #expect(second.isFavorite(pinned))
        #expect(second.isBlocked(blocked))
    }

    @Test("A file written before a list existed still loads")
    func toleratesAMissingList() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        // The lesson `AppSettings` already learned: the synthesized decoder
        // throws `keyNotFound` for a key an older build never wrote, and a
        // throw here drops the whole file — every pin the user has.
        let artwork = makeArtwork(id: "pinned")
        let entry = PhotoLibrary.Entry(artwork: artwork, date: Date())
        let encoded = try JSONEncoder().encode(entry)
        let json = "{\"favorites\":[\(String(decoding: encoded, as: UTF8.self))]}"
        try Data(json.utf8).write(to: folder.url.appending(path: "library.json"))

        let library = PhotoLibrary(directory: folder.url)
        #expect(library.isFavorite(artwork))
        #expect(library.history.isEmpty)
        #expect(library.blocked.isEmpty)
    }
}
