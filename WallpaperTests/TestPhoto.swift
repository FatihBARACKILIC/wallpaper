import Foundation
@testable import Wallpaper

/// Builds a `Photo` without going near the network. Only the fields the tests
/// actually read are worth varying, so everything else gets a fixed value.
func makePhoto(
    id: String = "Ry9WBo3qmoc",
    name: String = "Ales Krivec",
    username: String = "aleskrivec",
    description: String? = nil,
    altDescription: String? = nil,
    color: String? = nil,
    raw: String = "https://images.unsplash.com/photo-1?ixid=abc",
    full: String = "https://images.unsplash.com/photo-1?fm=jpg"
) -> Photo {
    Photo(
        id: id,
        width: 6000,
        height: 4000,
        description: description,
        altDescription: altDescription,
        color: color,
        urls: Photo.URLs(raw: raw, full: full),
        links: Photo.Links(
            html: "https://unsplash.com/photos/\(id)",
            downloadLocation: "https://api.unsplash.com/photos/\(id)/download"
        ),
        user: Photo.User(
            name: name,
            username: username,
            links: Photo.User.Links(html: "https://unsplash.com/@\(username)")
        )
    )
}

/// The same photo in the shape the app actually stores and applies.
func makeArtwork(
    id: String = "Ry9WBo3qmoc",
    name: String = "Ales Krivec",
    altDescription: String? = nil,
    color: String? = nil,
    raw: String = "https://images.unsplash.com/photo-1?ixid=abc"
) -> Artwork {
    makePhoto(id: id, name: name, altDescription: altDescription, color: color, raw: raw).artwork
}

/// An APOD picture. `hdurl` is deliberately separate from `url`: the client is
/// supposed to prefer the larger one.
func makeAPODArtwork(
    date: String = "2020-06-17",
    title: String = "Magnetic Streamlines of the Milky Way",
    copyright: String? = nil,
    hdurl: String? = "https://apod.nasa.gov/apod/image/2006/PolarisedMilkyWay_2048.jpg",
    url: String = "https://apod.nasa.gov/apod/image/2006/PolarisedMilkyWay_1080.jpg",
    mediaType: String = "image"
) -> Artwork? {
    NASAClient.Entry(
        date: date,
        title: title,
        mediaType: mediaType,
        url: url,
        hdurl: hdurl,
        copyright: copyright
    ).artwork
}

/// A Wallhaven wallpaper. `source` is the link the uploader credited the image
/// to; most wallpapers carry an empty string there rather than omitting it.
func makeWallhavenArtwork(
    id: String = "4olrgp",
    path: String = "https://w.wallhaven.cc/full/4o/wallhaven-4olrgp.jpg",
    source: String? = "",
    colors: [String]? = nil
) -> Artwork? {
    WallhavenClient.Entry(
        id: id,
        url: "https://wallhaven.cc/w/\(id)",
        path: path,
        source: source,
        colors: colors
    ).artwork
}

/// A photo from one of the user's own folders.
func makeLocalArtwork(at url: URL) -> Artwork {
    LocalFolder.artwork(for: url)
}

/// A throwaway directory, for the tests that need real files on disk.
struct TemporaryFolder {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "WallpaperTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, bytes: Int = 16) -> URL {
        let file = url.appending(path: name)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(repeating: 0xCD, count: bytes).write(to: file)
        return file
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}
