import CoreGraphics
import Foundation
import Testing
@testable import Wallpaper

/// `Artwork` is what every provider narrows down to, and what the app persists.
/// Both of those make its decoding a compatibility surface.
@Suite("Artwork")
struct ArtworkTests {

    // MARK: - Migration

    @Test("An index written before the app had more than one provider still reads")
    func decodesLegacyUnsplashShape() throws {
        // `photo-index.json` used to hold raw Unsplash photos. Failing to read
        // it would not be cosmetic: an entry that cannot be decoded is an entry
        // that cannot be credited, and those are evicted first — so a botched
        // migration quietly deletes every photo an existing user has.
        let legacy = try JSONEncoder().encode(["a.jpg": makePhoto(id: "abc", name: "Ales Krivec")])
        let decoded = try JSONDecoder().decode([String: Artwork].self, from: legacy)

        let artwork = try #require(decoded["a.jpg"])
        #expect(artwork.id == "abc")
        #expect(artwork.provider == .unsplash)
        #expect(artwork.creator == "Ales Krivec")
        #expect(artwork.downloadLocation?.contains("abc") == true)
        #expect(artwork.origin.url.absoluteString.contains("images.unsplash.com"))
    }

    @Test("A round trip through the current shape keeps every field")
    func roundTrips() throws {
        for artwork in [
            makeArtwork(),
            try #require(makeAPODArtwork()),
            try #require(makeWallhavenArtwork(source: "https://www.artstation.com/artwork/ZG4GeN")),
            makeLocalArtwork(at: URL(fileURLWithPath: "/tmp/a.png")),
        ] {
            let data = try JSONEncoder().encode(artwork)
            #expect(try JSONDecoder().decode(Artwork.self, from: data) == artwork)
        }
    }

    // MARK: - Download URLs

    @Test("Only Unsplash can be asked for a smaller file")
    func resizingIsUnsplashOnly() throws {
        let size = CGSize(width: 1920, height: 1080)

        let unsplash = try #require(makeArtwork().downloadURL(pixelSize: size))
        #expect(unsplash.absoluteString.contains("w=1920"))

        // APOD serves fixed files, so the resolution setting has nothing to act
        // on; adding parameters would just produce a URL that 404s.
        let apod = try #require(makeAPODArtwork()?.downloadURL(pixelSize: size))
        #expect(!apod.absoluteString.contains("w=1920"))
        #expect(apod.absoluteString.hasSuffix("_2048.jpg"))

        // Wallhaven serves the file as it was uploaded; size is negotiated on
        // the way in, with `atleast` on the search, not on the way out.
        let wallhaven = try #require(makeWallhavenArtwork()?.downloadURL(pixelSize: size))
        #expect(!wallhaven.absoluteString.contains("w=1920"))
        #expect(wallhaven.absoluteString.hasSuffix("wallhaven-4olrgp.jpg"))
    }

    @Test("A photo already on this Mac has nothing to download")
    func localHasNoDownload() {
        let artwork = makeLocalArtwork(at: URL(fileURLWithPath: "/Users/me/Pictures/a.jpg"))
        #expect(artwork.downloadURL(pixelSize: nil) == nil)
        #expect(artwork.origin.isLocalFile)
    }

    @Test("A downloaded copy keeps the format it was served in")
    func fileExtensionFollowsTheSource() throws {
        // Unsplash is asked for JPEG explicitly, but APOD serves what it has —
        // and a PNG saved as .jpg would misinform every other app.
        #expect(makeArtwork().fileExtension == "jpg")
        #expect(try #require(makeAPODArtwork(hdurl: "https://apod.nasa.gov/apod/image/x.png")).fileExtension == "png")
        #expect(try #require(makeAPODArtwork(hdurl: "https://apod.nasa.gov/apod/image/x.gif")).fileExtension == "gif")
        // Something unreadable falls back rather than inventing an extension.
        #expect(try #require(makeAPODArtwork(hdurl: "https://apod.nasa.gov/apod/image/x.mov")).fileExtension == "jpg")

        // Wallhaven serves plenty of PNGs.
        #expect(try #require(makeWallhavenArtwork()).fileExtension == "jpg")
        #expect(try #require(makeWallhavenArtwork(
            path: "https://w.wallhaven.cc/full/57/wallhaven-57g9k3.png"
        )).fileExtension == "png")
    }

    @Test("A photo stored before brightness existed still reads, and says it does not know")
    func lightnessIsOptional() throws {
        // Every entry in `photo-index.json` predates this field. One that
        // failed to decode would be treated as un-creditable and evicted
        // first — the same trap the provider migration guards.
        let stored = try JSONEncoder().encode(makeArtwork())
        let decoded = try JSONDecoder().decode(Artwork.self, from: stored)
        #expect(decoded.lightness == nil)

        // Unknown is not the same as dark: the ranking has to be able to tell
        // "nobody measured this" from "this is a night photo".
        #expect(makeArtwork(color: "#000000").lightness == 0)

        let measured = decoded.withLightness(0.42)
        #expect(measured.lightness == 0.42)
        #expect(try JSONDecoder().decode(
            Artwork.self, from: JSONEncoder().encode(measured)
        ).lightness == 0.42)

        // Filling it in a second time keeps the first answer: a measured file
        // beats a dominant colour, and it is measured first.
        #expect(measured.withLightness(nil).lightness == 0.42)
    }

    @Test("The same short ID under two providers is two different photos")
    func keyIsProviderQualified() throws {
        // Unsplash and Wallhaven IDs are both short strings of letters and
        // digits, so `id` alone would let one shadow the other in the history,
        // the pins and the block list.
        let unsplash = makeArtwork(id: "4olrgp")
        let wallhaven = try #require(makeWallhavenArtwork(id: "4olrgp"))

        #expect(unsplash.id == wallhaven.id)
        #expect(unsplash.key != wallhaven.key)
        #expect(wallhaven.key == "wallhaven:4olrgp")
    }
}

/// The Wallhaven mapping. A search answer names no photographer and carries no
/// caption, so most of this is about what the app must *not* claim.
@Suite("Wallhaven mapping")
struct WallhavenMappingTests {

    @Test("A wallpaper is credited to nobody, because the API names nobody")
    func namesNobody() throws {
        let artwork = try #require(makeWallhavenArtwork())
        #expect(artwork.creator == nil)
        // An empty `source` is the common case and must not become a link.
        #expect(artwork.creatorURL == nil)
        #expect(artwork.downloadLocation == nil)
        #expect(artwork.webURL?.absoluteString == "https://wallhaven.cc/w/4olrgp")
    }

    @Test("The link the uploader credited is offered when there is one")
    func keepsTheOriginalSource() throws {
        let artwork = try #require(
            makeWallhavenArtwork(source: "https://www.artstation.com/artwork/ZG4GeN")
        )
        #expect(artwork.creatorURL?.absoluteString == "https://www.artstation.com/artwork/ZG4GeN")
        // Still nobody named: a URL is not an author.
        #expect(artwork.creator == nil)
    }

    @Test("The ID stands in as a title, so a history row is not fifty identical lines")
    func idIsTheLabel() throws {
        let artwork = try #require(makeWallhavenArtwork())
        #expect(artwork.title == "4olrgp")
        #expect(artwork.shortLabel == "4olrgp")
    }

    @Test("A stored Wallhaven link is opened as it was saved")
    func noUTMRewriting() throws {
        // `sourceURL` rebuilds Unsplash links to carry the current application
        // name. Nothing else has UTM parameters to rebuild, and adding any
        // would be inventing a referral that was never registered.
        let artwork = try #require(makeWallhavenArtwork())
        #expect(artwork.sourceURL == artwork.webURL)
    }

    @Test("A real search payload decodes, fields and all")
    func decodesLiveShape() throws {
        // Captured from wallhaven.cc/api/v1/search. The response carries far
        // more than this — views, colours, file size — and decoding has to keep
        // ignoring all of it rather than break on a field being added.
        let json = Data("""
        [
          {
            "id": "4olrgp",
            "url": "https://wallhaven.cc/w/4olrgp",
            "short_url": "https://whvn.cc/4olrgp",
            "views": 3708,
            "source": "",
            "purity": "sfw",
            "category": "general",
            "dimension_x": 1936,
            "dimension_y": 2592,
            "file_type": "image/jpeg",
            "path": "https://w.wallhaven.cc/full/4o/wallhaven-4olrgp.jpg",
            "thumbs": { "large": "https://th.wallhaven.cc/lg/4o/4olrgp.jpg" }
          },
          {
            "id": "95mq9d",
            "url": "https://wallhaven.cc/w/95mq9d",
            "source": "https://unsplash.com/photos/vddccTqwal8",
            "purity": "sfw",
            "category": "general",
            "file_type": "image/png",
            "path": "https://w.wallhaven.cc/full/95/wallhaven-95mq9d.png",
            "thumbs": { "large": "https://th.wallhaven.cc/lg/95/95mq9d.jpg" }
          }
        ]
        """.utf8)

        let entries = try JSONDecoder().decode([WallhavenClient.Entry].self, from: json)
        let artworks = entries.compactMap(\.artwork)

        #expect(artworks.count == 2)
        #expect(artworks[0].creatorURL == nil)
        #expect(artworks[1].creatorURL?.absoluteString == "https://unsplash.com/photos/vddccTqwal8")
        #expect(artworks[1].fileExtension == "png")
        #expect(artworks.allSatisfy { $0.provider == .wallhaven })
    }
}

/// The APOD mapping, which has to cope with two things Unsplash never does:
/// days that are videos, and a missing full-size URL.
@Suite("NASA APOD mapping")
struct APODMappingTests {

    @Test("A video day is dropped rather than set as a wallpaper")
    func videosAreDropped() {
        #expect(makeAPODArtwork(mediaType: "video") == nil)
        #expect(makeAPODArtwork(mediaType: "other") == nil)
    }

    @Test("The full-size file is preferred, and stood in for when absent")
    func prefersHDURL() throws {
        let withHD = try #require(makeAPODArtwork())
        #expect(withHD.origin.url.absoluteString.hasSuffix("_2048.jpg"))

        // Not every entry in the live API carries `hdurl`.
        let withoutHD = try #require(makeAPODArtwork(hdurl: nil))
        #expect(withoutHD.origin.url.absoluteString.hasSuffix("_1080.jpg"))
    }

    @Test("Only a copyrighted picture names a holder")
    func copyrightIsOptional() throws {
        // NASA's own images omit the field entirely and are public domain.
        #expect(try #require(makeAPODArtwork()).creator == nil)
        // The live API pads the value with newlines.
        #expect(try #require(makeAPODArtwork(copyright: "\nBabak Tafreshi\n")).creator == "Babak Tafreshi")
    }

    @Test("The archive page is derived from the date")
    func pageURL() throws {
        let artwork = try #require(makeAPODArtwork(date: "2020-06-17"))
        #expect(artwork.webURL?.absoluteString == "https://apod.nasa.gov/apod/ap200617.html")
        #expect(artwork.id == "apod-2020-06-17")
    }

    @Test("An APOD photo has no download to report")
    func nothingToReport() throws {
        // Unlike Unsplash, using one costs no second request.
        #expect(try #require(makeAPODArtwork()).downloadLocation == nil)
    }

    @Test("A real API payload decodes, fields and all")
    func decodesLiveShape() throws {
        // Captured from api.nasa.gov. Guards against a field name drifting:
        // `media_type` and the optional `hdurl`/`copyright` are the whole
        // reason the mapping exists.
        let json = Data("""
        [
          {
            "date": "2020-06-17",
            "explanation": "What role do magnetic fields play…",
            "hdurl": "https://apod.nasa.gov/apod/image/2006/PolarisedMilkyWay_Planck_2048.jpg",
            "media_type": "image",
            "service_version": "v1",
            "title": "Magnetic Streamlines of the Milky Way",
            "url": "https://apod.nasa.gov/apod/image/2006/PolarisedMilkyWay_Planck_1080.jpg"
          },
          {
            "copyright": "Babak Tafreshi",
            "date": "2013-03-14",
            "explanation": "In silhouette against the colorful evening twilight…",
            "hdurl": "https://apod.nasa.gov/apod/image/1303/PanStarrsMoon-LaPalma.jpg",
            "media_type": "image",
            "service_version": "v1",
            "title": "Clouds, Comet and Crescent Moon",
            "url": "https://apod.nasa.gov/apod/image/1303/PanStarrsMoon-LaPalma-s900.jpg"
          },
          {
            "date": "2019-01-01",
            "explanation": "A film, not a photograph.",
            "media_type": "video",
            "service_version": "v1",
            "title": "Ultima Thule Flyby",
            "url": "https://www.youtube.com/embed/example"
          }
        ]
        """.utf8)

        let entries = try JSONDecoder().decode([NASAClient.Entry].self, from: json)
        #expect(entries.count == 3)

        let artworks = entries.compactMap(\.artwork)
        // The video is dropped, so two of the three survive.
        #expect(artworks.count == 2)
        #expect(artworks[0].creator == nil)
        #expect(artworks[1].creator == "Babak Tafreshi")
        #expect(artworks[0].origin.url.absoluteString.hasSuffix("_2048.jpg"))
        #expect(artworks[0].webURL?.absoluteString == "https://apod.nasa.gov/apod/ap200617.html")
    }
}
