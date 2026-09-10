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
    raw: String = "https://images.unsplash.com/photo-1?ixid=abc",
    full: String = "https://images.unsplash.com/photo-1?fm=jpg"
) -> Photo {
    Photo(
        id: id,
        width: 6000,
        height: 4000,
        description: description,
        altDescription: altDescription,
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
