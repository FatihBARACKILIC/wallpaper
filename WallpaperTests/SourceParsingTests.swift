import Foundation
import Testing
@testable import Wallpaper

/// `Source(input:)` accepts whatever the user pastes. It is the most exposed
/// piece of parsing in the app, and the only place a user can feed arbitrary
/// text straight into a model.
@Suite("Source parsing")
struct SourceParsingTests {

    /// `Source` synthesises equality from a per-instance UUID, so comparing two
    /// values would always fail. Only what the parser decided matters here.
    private func check(
        _ input: String,
        _ kind: Source.Kind,
        _ value: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let source = Source(input: input) else {
            Issue.record("\(input) did not parse", sourceLocation: sourceLocation)
            return
        }
        #expect(source.kind == kind, sourceLocation: sourceLocation)
        #expect(source.value == value, sourceLocation: sourceLocation)
    }

    @Test("Topic links, both spellings")
    func topics() {
        check("https://unsplash.com/t/nature", .topic, "nature")
        check("https://unsplash.com/topics/wallpapers", .topic, "wallpapers")
    }

    @Test("A pasted link without a scheme still parses")
    func schemeless() {
        check("unsplash.com/t/nature", .topic, "nature")
    }

    @Test("Collection links keep the numeric ID, whatever follows it")
    func collections() {
        check("https://unsplash.com/collections/1234", .collection, "1234")
        check("https://unsplash.com/collections/1234/mountain-photos", .collection, "1234")
        check("https://unsplash.com/collections/curated/5678", .collection, "5678")
    }

    @Test("Search links turn their slug back into words")
    func searchPath() {
        check("https://unsplash.com/s/photos/misty-forest", .search, "misty forest")
    }

    @Test("A ?query= search URL is recognised too")
    func searchQuery() {
        check("https://unsplash.com/search/photos?query=alpine%20lake", .search, "alpine lake")
    }

    @Test("Anything that is not an Unsplash URL becomes a search")
    func fallsBackToSearch() {
        check("misty forest", .search, "misty forest")
        check("https://example.com/t/nature", .search, "https://example.com/t/nature")
    }

    @Test("Empty input is rejected rather than becoming an empty search")
    func rejectsEmpty() {
        #expect(Source(input: "") == nil)
        #expect(Source(input: "   \n ") == nil)
    }

    @Test("Surrounding whitespace is trimmed")
    func trimsWhitespace() {
        check("  https://unsplash.com/t/nature  ", .topic, "nature")
    }

    @Test("The label tags the kind, and prefers a resolved title")
    func shortLabel() {
        #expect(Source(kind: .topic, value: "nature").shortLabel == "t/nature")
        #expect(Source(kind: .search, value: "misty forest").shortLabel == "s/misty forest")
        #expect(Source(kind: .collection, value: "1234").shortLabel == "c/1234")
        #expect(Source(kind: .collection, value: "1234", title: "Wallpapers").shortLabel == "c/Wallpapers")
    }

    @Test("Only an unresolved collection needs a lookup")
    func needsTitle() {
        #expect(Source(kind: .collection, value: "1234").needsTitle)
        #expect(!Source(kind: .collection, value: "1234", title: "Wallpapers").needsTitle)
        #expect(!Source(kind: .topic, value: "nature").needsTitle)
        #expect(!Source(kind: .search, value: "forest").needsTitle)
    }

    // MARK: - NASA APOD

    @Test("APOD is recognised by name and by link")
    func apodByNameAndLink() {
        check("apod", .apod, Source.apodValue)
        check("NASA APOD", .apod, Source.apodValue)
        check("Astronomy Picture of the Day", .apod, Source.apodValue)
        check("https://apod.nasa.gov/apod/ap200617.html", .apod, Source.apodValue)
        check("apod.nasa.gov", .apod, Source.apodValue)
    }

    @Test("A search that merely mentions NASA stays a search")
    func apodDoesNotSwallowSearches() {
        // Only the exact names count, or "nasa rocket launch" would silently
        // become the APOD source instead of an Unsplash search.
        check("nasa rocket launch", .search, "nasa rocket launch")
        check("apod photography", .search, "apod photography")
    }

    // MARK: - Folders

    @Test("A path that really is a folder becomes a folder source")
    func folderPath() {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        check(folder.url.path, .folder, folder.url.standardizedFileURL.path)
        check("file://\(folder.url.path)", .folder, folder.url.standardizedFileURL.path)
    }

    @Test("A path that is not a folder is still just a search")
    func nonFolderPathsStaySearches() {
        // Checking the disk rather than the spelling is what keeps a search
        // containing a slash from being mistaken for a folder.
        let missing = "/definitely/not/here-\(UUID().uuidString)"
        check(missing, .search, missing)
    }

    @Test("A folder source is named after the folder, not its whole path")
    func folderTitle() {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        let source = Source.folder(at: folder.url)
        #expect(source.title == folder.url.lastPathComponent)
        #expect(source.shortLabel == "f/\(folder.url.lastPathComponent)")
    }

    // MARK: - Keys each kind needs

    @Test("Only the API kinds are tied to a provider that needs a key")
    func providerPerKind() {
        #expect(Source.Kind.topic.provider == .unsplash)
        #expect(Source.Kind.collection.provider == .unsplash)
        #expect(Source.Kind.search.provider == .unsplash)
        #expect(Source.Kind.apod.provider == .apod)
        #expect(Source.Kind.folder.provider == .local)
    }
}
