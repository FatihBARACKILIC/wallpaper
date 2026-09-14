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

    @Test("Only an ID the user cannot read needs a lookup")
    func needsTitle() {
        #expect(Source(kind: .collection, value: "1234").needsTitle)
        #expect(!Source(kind: .collection, value: "1234", title: "Wallpapers").needsTitle)
        #expect(!Source(kind: .topic, value: "nature").needsTitle)
        #expect(!Source(kind: .search, value: "forest").needsTitle)

        // A Wallhaven tag is a number too; a Wallhaven query is already words.
        #expect(Source(kind: .wallhaven, value: "id:37").needsTitle)
        #expect(!Source(kind: .wallhaven, value: "id:37", title: "nature").needsTitle)
        #expect(!Source(kind: .wallhaven, value: "mountains").needsTitle)
        #expect(!Source.wallhaven().needsTitle)
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
        #expect(Source.Kind.wallhaven.provider == .wallhaven)
        #expect(Source.Kind.folder.provider == .local)
    }

    // MARK: - Wallhaven

    @Test("Wallhaven has to be named, because plain words are an Unsplash search")
    func wallhavenByName() {
        check("wallhaven", .wallhaven, "")
        check("Wallhaven", .wallhaven, "")
        check("wallhaven.cc", .wallhaven, "")
        check("wallhaven mountains at dusk", .wallhaven, "mountains at dusk")
        // The query is trimmed at the ends and left alone in the middle.
        check("Wallhaven  inner  spacing kept ", .wallhaven, "inner  spacing kept")
    }

    @Test("A word that merely starts with wallhaven stays a search")
    func wallhavenDoesNotSwallowSearches() {
        check("wallhavens", .search, "wallhavens")
        check("wallhaven-inspired", .search, "wallhaven-inspired")
    }

    @Test("Pasted Wallhaven links keep their query")
    func wallhavenLinks() {
        check("https://wallhaven.cc/search?q=misty%20forest", .wallhaven, "misty forest")
        check("wallhaven.cc/search?q=forest&categories=111", .wallhaven, "forest")
        // A tag page is a search for that tag, which the API spells `id:<n>`.
        check("https://wallhaven.cc/tag/37", .wallhaven, "id:37")
    }

    @Test("A Wallhaven link that is not a query is all of Wallhaven")
    func wallhavenWholeSite() {
        // /latest, /hot and a single wallpaper's page are none of them a
        // search, and refusing them would drop the user back to an Unsplash
        // search for the URL they pasted.
        check("https://wallhaven.cc/latest", .wallhaven, "")
        check("https://wallhaven.cc/w/4olrgp", .wallhaven, "")
        check("https://whvn.cc/4olrgp", .wallhaven, "")
    }

    @Test("All of Wallhaven is named rather than shown as an empty label")
    func wallhavenWholeSiteTitle() {
        #expect(Source.wallhaven().shortLabel == "w/Everything")
        #expect(Source.wallhaven(query: "forest").shortLabel == "w/forest")
        #expect(Source.wallhaven(query: "  forest  ").value == "forest")
    }

    @Test("Only a numeric tag is a tag")
    func wallhavenTagID() {
        #expect(Source(kind: .wallhaven, value: "id:37").wallhavenTagID == "37")
        #expect(Source(kind: .wallhaven, value: "id:").wallhavenTagID == nil)
        #expect(Source(kind: .wallhaven, value: "id:not-a-number").wallhavenTagID == nil)
        #expect(Source(kind: .wallhaven, value: "identity").wallhavenTagID == nil)
        #expect(Source(kind: .search, value: "id:37").wallhavenTagID == nil)
    }
}
