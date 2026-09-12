import Foundation
import Testing
@testable import Wallpaper

/// A folder source reads the user's own files. The rules that matter here are
/// what counts as an image, and that nothing is ever written back.
@Suite("Local folder")
struct LocalFolderTests {

    @Test("Images are found, including in subfolders")
    func findsImagesRecursively() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        folder.write("one.jpg")
        folder.write("two.PNG")
        folder.write("nested/three.heic")
        folder.write("nested/deeper/four.jpeg")

        let found = try LocalFolder.images(in: folder.url).map(\.lastPathComponent)
        #expect(Set(found) == ["one.jpg", "two.PNG", "three.heic", "four.jpeg"])
    }

    @Test("Anything that is not an image is ignored")
    func skipsNonImages() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        folder.write("keep.jpg")
        folder.write("notes.txt")
        folder.write("movie.mov")
        folder.write("archive.zip")

        let found = try LocalFolder.images(in: folder.url)
        #expect(found.map(\.lastPathComponent) == ["keep.jpg"])
    }

    @Test("A folder with no images says so rather than returning nothing")
    func emptyFolderThrows() {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }
        folder.write("notes.txt")

        #expect(throws: LocalFolderError.self) {
            _ = try LocalFolder.images(in: folder.url)
        }
    }

    @Test("A folder that is gone is reported as unavailable, not as empty")
    func missingFolderThrows() {
        // This is what an unplugged external drive looks like, and the message
        // the user gets has to point at the right problem.
        let missing = URL(fileURLWithPath: "/definitely/not/here-\(UUID().uuidString)")
        #expect(throws: LocalFolderError.self) {
            _ = try LocalFolder.images(in: missing)
        }
        #expect(LocalFolder.imageCount(in: missing) == nil)
    }

    @Test("The photo on screen is avoided, so the wallpaper visibly changes")
    func avoidsWhatIsOnScreen() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        let a = folder.write("a.jpg")
        folder.write("b.jpg")

        let picked = try LocalFolder.randomArtworks(
            count: 1,
            from: .folder(at: folder.url),
            avoiding: [a.standardizedFileURL]
        )
        #expect(picked.map(\.origin.url.lastPathComponent) == ["b.jpg"])
    }

    @Test("A folder holding one photo still works")
    func singlePhotoFolder() throws {
        // Avoiding what is on screen is given up rather than returning nothing.
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }
        let only = folder.write("only.jpg")

        let picked = try LocalFolder.randomArtworks(
            count: 2,
            from: .folder(at: folder.url),
            avoiding: [only.standardizedFileURL]
        )
        #expect(picked.count == 2)
        #expect(picked.allSatisfy { $0.origin.url.lastPathComponent == "only.jpg" })
    }

    @Test("Reading a folder never changes it")
    func readOnly() throws {
        // The files belong to the user. Nothing here may copy, rename or delete
        // one, so the folder must look identical afterwards.
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }
        folder.write("a.jpg")
        folder.write("b.jpg")

        let before = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        _ = try LocalFolder.randomArtworks(count: 2, from: .folder(at: folder.url), avoiding: [])
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()

        #expect(before == after)
    }

    @Test("A local photo is applied where it lies, never through the cache")
    func neverEntersTheCache() async {
        let artwork = makeLocalArtwork(at: URL(fileURLWithPath: "/Users/me/Pictures/a.jpg"))
        let cache = ImageCache(directory: TemporaryFolder().url)

        // Copying it in would put a user file under the storage limit, where
        // eviction could delete it.
        await #expect(throws: CacheError.self) {
            _ = try await cache.download(artwork, pixelSize: nil)
        }
    }

    @Test("A local photo is named after its file and needs no credit")
    func attribution() {
        let artwork = makeLocalArtwork(at: URL(fileURLWithPath: "/Users/me/Pictures/Iceland 2025.jpg"))
        #expect(artwork.title == "Iceland 2025")
        #expect(artwork.creator == nil)
        #expect(artwork.provider == .local)
    }
}
