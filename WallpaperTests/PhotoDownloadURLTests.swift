import CoreGraphics
import Foundation
import Testing
@testable import Wallpaper

/// Resizing happens at Unsplash, so this URL decides whether a photo costs
/// about 1 MB or about 30 MB.
@Suite("Photo download URL")
struct PhotoDownloadURLTests {

    private func parameters(_ url: URL?) -> [String: String] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
    }

    @Test("A pixel size crops at the CDN")
    func sizedDownload() {
        let items = parameters(makePhoto().downloadURL(pixelSize: CGSize(width: 3840, height: 2160)))
        #expect(items["w"] == "3840")
        #expect(items["h"] == "2160")
        #expect(items["fit"] == "crop")
        #expect(items["crop"] == "entropy")
        #expect(items["q"] == "85")
        #expect(items["fm"] == "jpg")
    }

    @Test("Full resolution drops the size but still transcodes")
    func originalStillTranscodes() {
        // The raw file can be a 50 MB uncompressed image, so `fm=jpg` matters
        // even when the dimensions are left alone.
        let items = parameters(makePhoto().downloadURL(pixelSize: nil))
        #expect(items["w"] == nil)
        #expect(items["h"] == nil)
        #expect(items["q"] == "85")
        #expect(items["fm"] == "jpg")
    }

    @Test("Sizing parameters already on the raw URL are replaced, not added to")
    func replacesExistingParameters() {
        let photo = makePhoto(raw: "https://images.unsplash.com/photo-1?ixid=abc&w=9999&h=9999&q=20&dpr=3")
        guard let url = photo.downloadURL(pixelSize: CGSize(width: 1920, height: 1080)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            Issue.record("no download URL")
            return
        }

        let items = components.queryItems ?? []
        #expect(items.filter { $0.name == "w" }.count == 1)
        #expect(items.first { $0.name == "w" }?.value == "1920")
        #expect(items.first { $0.name == "q" }?.value == "85")
        #expect(items.contains { $0.name == "dpr" } == false)
        #expect(items.first { $0.name == "ixid" }?.value == "abc")
    }

    @Test("The photo's own identifiers survive into the CDN URL")
    func keepsPath() {
        #expect(makePhoto().downloadURL(pixelSize: nil)?.path == "/photo-1")
    }
}
