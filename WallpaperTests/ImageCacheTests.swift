import Foundation
import Testing
@testable import Wallpaper

/// Serves any request from memory, so the cache can be exercised without the
/// network. A URL containing "fail" answers 500 — that keeps the stub stateless
/// and safe to run in parallel.
private nonisolated final class StubURLProtocol: URLProtocol {
    static let body = Data(repeating: 0xAB, count: 1024)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://example.com")!
        let status = url.absoluteString.contains("fail") ? 500 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Image cache")
struct ImageCacheTests {

    /// A fresh Application Support stand-in. `photo-index.json` lives beside
    /// the photo folder, so the tests need both levels.
    private struct Sandbox {
        let root: URL
        var photos: URL { root.appending(path: "Photos", directoryHint: .isDirectory) }
        var indexURL: URL { root.appending(path: "photo-index.json") }

        init() {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "WallpaperTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        }

        func writePhoto(_ name: String, bytes: Int = 1024, created: Date = Date()) {
            let url = photos.appending(path: name)
            try? Data(repeating: 0xCD, count: bytes).write(to: url)
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }

        func writeIndex(_ entries: [String: Photo]) {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: indexURL)
        }

        func names() -> Set<String> {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: photos.path)) ?? []
            return Set(contents)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - Naming

    @Test("A downloaded file is named so the photo can be found on Unsplash again")
    func filenameCarriesPhotographerAndID() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let photo = makePhoto(id: "Ry9WBo3qmoc", name: "Ales Krivec", altDescription: "misty mountain lake")
        let url = try await cache.download(photo, pixelSize: nil)
        let name = url.lastPathComponent

        #expect(name.contains("Ales Krivec"))
        #expect(name.contains("misty-mountain-lake"))
        // The ID is what makes unsplash.com/photos/<id> work, so it must be last.
        #expect(name.hasSuffix("Ry9WBo3qmoc.jpg"))
    }

    @Test("A photo with no caption is still named after its photographer and ID")
    func filenameWithoutCaption() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let url = try await cache.download(makePhoto(name: "Jane Doe"), pixelSize: nil)

        #expect(url.lastPathComponent.contains("Jane Doe"))
        #expect(url.lastPathComponent.hasSuffix("Ry9WBo3qmoc.jpg"))
    }

    @Test("Characters that would break the path are stripped from the name")
    func filenameSanitised() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let photo = makePhoto(name: "A/B\\C", altDescription: "forest/lake")
        let url = try await cache.download(photo, pixelSize: nil)

        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.lastPathComponent.contains("\\"))
    }

    @Test("A very long caption is trimmed, never the ID")
    func longCaptionTrimmed() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let photo = makePhoto(altDescription: String(repeating: "mountain ", count: 40))
        let url = try await cache.download(photo, pixelSize: nil)

        #expect(url.lastPathComponent.utf8.count <= 250)
        #expect(url.lastPathComponent.hasSuffix("Ry9WBo3qmoc.jpg"))
        // Cut at a word boundary, so the name still reads as a phrase.
        #expect(!url.lastPathComponent.contains("moun —"))
    }

    // MARK: - Downloading

    @Test("A failed download leaves nothing behind")
    func failedDownloadWritesNothing() async {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let photo = makePhoto(raw: "https://images.unsplash.com/fail-photo")

        await #expect(throws: (any Error).self) {
            _ = try await cache.download(photo, pixelSize: nil)
        }
        #expect(sandbox.names().isEmpty)
    }

    @Test("Downloading the same photo twice re-uses the file")
    func reusesExistingFile() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let photo = makePhoto()

        let first = try await cache.download(photo, pixelSize: nil)
        let second = try await cache.download(photo, pixelSize: nil)

        #expect(first == second)
        #expect(sandbox.names().count == 1)
    }

    @Test("A downloaded photo is recorded, so it can be credited when re-used")
    func downloadIsIndexed() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let photo = makePhoto()
        _ = try await cache.download(photo, pixelSize: nil)

        #expect(cache.entries().map(\.photo.id) == [photo.id])
    }

    // MARK: - Eviction

    @Test("Files that cannot be credited are evicted before older ones that can")
    func unattributableFilesGoFirst() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        // The indexed file is much older, so age alone would evict it first.
        sandbox.writePhoto("indexed.jpg", created: Date().addingTimeInterval(-86_400 * 30))
        sandbox.writePhoto("unindexed.jpg", created: Date())
        sandbox.writeIndex(["indexed.jpg": makePhoto()])

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        cache.enforce(StorageLimit(isEnabled: true, maxPhotos: 1, maxBytes: .max), pinned: [])

        // Without an index entry the photographer cannot be credited, so the
        // file can never be re-used — keeping it would crowd out one that can.
        #expect(sandbox.names() == ["indexed.jpg"])
    }

    @Test("Among files that can be credited, the oldest goes first")
    func oldestGoesFirst() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        sandbox.writePhoto("old.jpg", created: Date().addingTimeInterval(-86_400))
        sandbox.writePhoto("new.jpg", created: Date())
        sandbox.writeIndex(["old.jpg": makePhoto(id: "old"), "new.jpg": makePhoto(id: "new")])

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        cache.enforce(StorageLimit(isEnabled: true, maxPhotos: 1, maxBytes: .max), pinned: [])

        #expect(sandbox.names() == ["new.jpg"])
    }

    @Test("The wallpapers on screen are never evicted")
    func pinnedFilesSurvive() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        sandbox.writePhoto("old.jpg", created: Date().addingTimeInterval(-86_400))
        sandbox.writePhoto("new.jpg", created: Date())
        sandbox.writeIndex(["old.jpg": makePhoto(id: "old"), "new.jpg": makePhoto(id: "new")])

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        let pinned = sandbox.photos.appending(path: "old.jpg")
        cache.enforce(StorageLimit(isEnabled: true, maxPhotos: 1, maxBytes: .max), pinned: [pinned])

        // "old.jpg" would have gone first on age, but it is on screen.
        #expect(sandbox.names() == ["old.jpg"])
    }

    @Test("The byte limit evicts even when the photo count is fine")
    func byteLimitEvicts() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        sandbox.writePhoto("old.jpg", bytes: 4096, created: Date().addingTimeInterval(-86_400))
        sandbox.writePhoto("new.jpg", bytes: 4096, created: Date())
        sandbox.writeIndex(["old.jpg": makePhoto(id: "old"), "new.jpg": makePhoto(id: "new")])

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        cache.enforce(StorageLimit(isEnabled: true, maxPhotos: 100, maxBytes: 5000), pinned: [])

        #expect(sandbox.names() == ["new.jpg"])
    }

    @Test("A disabled limit keeps everything")
    func disabledLimitKeepsEverything() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        for index in 0..<5 { sandbox.writePhoto("photo-\(index).jpg") }

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        cache.enforce(.unlimited, pinned: [])

        #expect(sandbox.names().count == 5)
        #expect(cache.stats.count == 5)
    }

    @Test("Evicting forgets the index entries of the files it removed")
    func evictionPrunesIndex() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        sandbox.writePhoto("old.jpg", created: Date().addingTimeInterval(-86_400))
        sandbox.writePhoto("new.jpg", created: Date())
        sandbox.writeIndex(["old.jpg": makePhoto(id: "old"), "new.jpg": makePhoto(id: "new")])

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        cache.enforce(StorageLimit(isEnabled: true, maxPhotos: 1, maxBytes: .max), pinned: [])

        #expect(cache.entries().map(\.photo.id) == ["new"])
    }

    // MARK: - Clearing

    @Test("Deleting the cache keeps the wallpapers on screen")
    func clearKeepsPinned() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        sandbox.writePhoto("a.jpg")
        sandbox.writePhoto("b.jpg")
        sandbox.writePhoto("c.jpg")

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        cache.clear(keeping: [sandbox.photos.appending(path: "b.jpg")])

        #expect(sandbox.names() == ["b.jpg"])
        #expect(cache.stats.count == 1)
    }

    @Test("Stats report what is actually on disk")
    func statsReflectDisk() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }

        sandbox.writePhoto("a.jpg", bytes: 2048)
        sandbox.writePhoto("b.jpg", bytes: 1024)

        let cache = ImageCache(session: stubbedSession(), directory: sandbox.photos)
        cache.enforce(.unlimited, pinned: [])

        #expect(cache.stats.count == 2)
        #expect(cache.stats.bytes == 3072)
    }
}
