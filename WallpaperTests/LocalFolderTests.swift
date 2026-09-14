import CoreGraphics
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

    @Test("A blocked photo is never picked, even when it is the only fresh one")
    func skipsBlocked() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        let blocked = folder.write("blocked.jpg")
        folder.write("fine.jpg")

        // The "avoiding" pool is given up when it empties, so a blocked photo
        // could otherwise slip back in as the last resort.
        let picked = try LocalFolder.randomArtworks(
            count: 1,
            from: .folder(at: folder.url),
            avoiding: [folder.url.appending(path: "fine.jpg").standardizedFileURL],
            blocked: [makeLocalArtwork(at: blocked).key]
        )

        #expect(picked.map(\.origin.url.lastPathComponent) == ["fine.jpg"])
    }

    @Test("A folder where everything is blocked says so, rather than blaming the folder")
    func allBlocked() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }
        let only = folder.write("only.jpg")

        // Source specific, so the next source gets a turn — but "no images
        // found" would send the user looking for a problem with the folder.
        let thrown = #expect(throws: LocalFolderError.self) {
            _ = try LocalFolder.randomArtworks(
                count: 1,
                from: .folder(at: folder.url),
                avoiding: [],
                blocked: [makeLocalArtwork(at: only).key]
            )
        }

        guard case .allBlocked = thrown else {
            Issue.record("expected allBlocked, got \(String(describing: thrown))")
            return
        }
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

    // MARK: - Fitting the screen

    @Test("Cropping is measured as the fraction of the photo thrown away")
    func cropFraction() {
        let wide = 16.0 / 9

        // Same shape, nothing lost.
        #expect(LocalFolder.cropFraction(photo: CGSize(width: 3840, height: 2160), screenRatio: wide) == 0)
        #expect(LocalFolder.cropFraction(photo: CGSize(width: 1600, height: 900), screenRatio: wide) == 0)

        // 4:3 on a 16:9 display loses a quarter of itself.
        let fourThree = LocalFolder.cropFraction(photo: CGSize(width: 4000, height: 3000), screenRatio: wide)
        #expect(abs(fourThree - 0.25) < 0.001)

        // A phone photo loses well over half, which is the case this exists for.
        let portrait = LocalFolder.cropFraction(photo: CGSize(width: 1200, height: 1600), screenRatio: wide)
        #expect(portrait > 0.55)
        #expect(portrait > fourThree)

        // Symmetric: a panorama on a square display is cropped just as hard.
        #expect(LocalFolder.cropFraction(photo: CGSize(width: 1000, height: 1000), screenRatio: 4)
            == LocalFolder.cropFraction(photo: CGSize(width: 4000, height: 1000), screenRatio: 1))
    }

    @Test("A size that makes no sense is not treated as a bad fit")
    func cropFractionEdges() {
        #expect(LocalFolder.cropFraction(photo: .zero, screenRatio: 1.78) == 0)
        #expect(LocalFolder.cropFraction(photo: CGSize(width: 100, height: 0), screenRatio: 1.78) == 0)
        #expect(LocalFolder.cropFraction(photo: CGSize(width: 100, height: 100), screenRatio: 0) == 0)
    }

    @Test("A folder of phone photos offers its landscape ones first")
    func prefersPhotosThatFitTheScreen() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        // What a real camera roll looks like: mostly portrait.
        for index in 0..<12 {
            writePNG(width: 90, height: 160, to: folder.url.appending(path: "portrait\(index).png"))
        }
        for index in 0..<3 {
            writePNG(width: 160, height: 90, to: folder.url.appending(path: "landscape\(index).png"))
        }

        let picked = try LocalFolder.randomArtworks(
            count: 3,
            from: .folder(at: folder.url),
            avoiding: [],
            fitting: 16.0 / 9
        )

        #expect(picked.count == 3)
        #expect(picked.allSatisfy { $0.origin.url.lastPathComponent.hasPrefix("landscape") })
    }

    @Test("It is a preference, not a filter — a folder of only portraits still works")
    func neverDropsThePhotosItHas() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        for index in 0..<8 {
            writePNG(width: 90, height: 160, to: folder.url.appending(path: "portrait\(index).png"))
        }

        let picked = try LocalFolder.randomArtworks(
            count: 3,
            from: .folder(at: folder.url),
            avoiding: [],
            fitting: 16.0 / 9
        )
        #expect(picked.count == 3)
    }

    @Test("A file whose size cannot be read is sorted last, not thrown away")
    func unreadableSizesSurvive() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        // A folder scan only checks the extension, so bytes that are not an
        // image really do reach here.
        for index in 0..<6 { folder.write("broken\(index).jpg") }
        writePNG(width: 160, height: 90, to: folder.url.appending(path: "real.png"))

        let picked = try LocalFolder.randomArtworks(
            count: 4,
            from: .folder(at: folder.url),
            avoiding: [],
            fitting: 16.0 / 9
        )

        #expect(picked.count == 4)
        // The one real landscape image comes first; the unreadable ones fill in
        // behind it rather than being dropped.
        #expect(picked.first?.origin.url.lastPathComponent == "real.png")
    }

    @Test("With no screen to fit, the draw is left alone")
    func noRatioChangesNothing() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }
        for index in 0..<10 {
            writePNG(width: 90, height: 160, to: folder.url.appending(path: "p\(index).png"))
        }

        let picked = try LocalFolder.randomArtworks(
            count: 3, from: .folder(at: folder.url), avoiding: []
        )
        #expect(picked.count == 3)
    }
}
