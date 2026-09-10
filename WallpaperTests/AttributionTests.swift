import Foundation
import Testing
@testable import Wallpaper

/// Every outbound Unsplash link has to carry `utm_source` and
/// `utm_medium=referral`; the API guidelines are not optional and nothing in
/// the UI would reveal a link that quietly lost them.
///
/// `UnsplashAttribution.applicationName` is global mutable state, so this suite
/// runs serially and restores the default — otherwise a parallel test reading a
/// link would see whichever name won the race.
@Suite("Attribution links", .serialized)
struct AttributionTests {

    private func parameters(_ url: URL?) -> [String: String] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
    }

    private func withApplicationName(_ name: String, _ body: () -> Void) {
        let original = UnsplashAttribution.applicationName
        UnsplashAttribution.applicationName = name
        defer { UnsplashAttribution.applicationName = original }
        body()
    }

    @Test("Both required parameters are appended")
    func addsParameters() {
        withApplicationName(UnsplashAttribution.defaultApplicationName) {
            let items = parameters(UnsplashAttribution.link("https://unsplash.com/photos/abc"))
            #expect(items["utm_source"] == "wallpaper")
            #expect(items["utm_medium"] == "referral")
        }
    }

    @Test("An existing query string survives")
    func keepsExistingQuery() {
        withApplicationName(UnsplashAttribution.defaultApplicationName) {
            let items = parameters(UnsplashAttribution.link("https://unsplash.com/photos/abc?ixid=xyz"))
            #expect(items["ixid"] == "xyz")
            #expect(items["utm_medium"] == "referral")
        }
    }

    @Test("Applying it twice does not duplicate the parameters")
    func idempotent() {
        withApplicationName(UnsplashAttribution.defaultApplicationName) {
            guard let once = UnsplashAttribution.link("https://unsplash.com/photos/abc"),
                  let twice = UnsplashAttribution.link(once.absoluteString),
                  let components = URLComponents(url: twice, resolvingAgainstBaseURL: false)
            else {
                Issue.record("link building failed")
                return
            }
            #expect((components.queryItems ?? []).filter { $0.name == "utm_source" }.count == 1)
            #expect((components.queryItems ?? []).filter { $0.name == "utm_medium" }.count == 1)
        }
    }

    @Test("The registered application name is slugified for utm_source")
    func slugifiesName() {
        withApplicationName("My Wallpaper App!") {
            #expect(parameters(UnsplashAttribution.link("https://unsplash.com/"))["utm_source"] == "my_wallpaper_app")
        }
    }

    @Test("A name with nothing usable in it falls back rather than sending an empty source")
    func emptyNameFallsBack() {
        withApplicationName("!!!") {
            #expect(parameters(UnsplashAttribution.link("https://unsplash.com/"))["utm_source"] == "wallpaper")
        }
    }

    @Test("Source links carry the parameters as well")
    func sourceLinks() {
        withApplicationName(UnsplashAttribution.defaultApplicationName) {
            for source in [
                Source(kind: .topic, value: "nature"),
                Source(kind: .collection, value: "1234"),
                Source(kind: .search, value: "misty forest"),
            ] {
                let items = parameters(source.webURL)
                #expect(items["utm_source"] == "wallpaper", "\(source.shortLabel)")
                #expect(items["utm_medium"] == "referral", "\(source.shortLabel)")
            }
        }
    }

    @Test("A search link percent-encodes its query into the path")
    func searchLinkEncodesQuery() {
        withApplicationName(UnsplashAttribution.defaultApplicationName) {
            let url = Source(kind: .search, value: "misty forest").webURL
            #expect(url?.absoluteString.contains("/s/photos/misty%20forest") == true)
        }
    }

    @Test("Photo and photographer links are both attributed")
    func photoLinks() {
        withApplicationName(UnsplashAttribution.defaultApplicationName) {
            let photo = makePhoto()
            #expect(parameters(photo.webURL)["utm_medium"] == "referral")
            #expect(parameters(photo.photographerURL)["utm_medium"] == "referral")
            #expect(photo.photographerURL?.path == "/@aleskrivec")
        }
    }
}
