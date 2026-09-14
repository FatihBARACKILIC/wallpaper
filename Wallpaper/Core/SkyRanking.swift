import Foundation

/// Orders a draw of photos by how well each suits the sky right now.
///
/// Its own type because it is a pure function of a batch and a sun position:
/// nothing here reads a setting, touches the disk on the app's behalf or knows
/// what a wallpaper is. `nonisolated`, so the measuring it sometimes has to do
/// happens where that work belongs rather than on the main actor.
nonisolated enum SkyRanking {
    /// Orders a draw so the photos that suit the sky come first.
    ///
    /// A preference, never a filter. Nothing is dropped: a draw where every
    /// photo is wrong for the hour still changes the wallpaper, because a
    /// desktop that freezes at dusk is a worse outcome than one wearing a
    /// bright photo at night. Photos whose brightness nobody knows sort last
    /// but stay in the list for the same reason.
    ///
    /// Stable within equal fits, so the shuffle the draw already has is not
    /// undone.
    static func ranked(_ artworks: [Artwork], for sunlight: Sunlight?) async -> [Artwork] {
        guard let sunlight, artworks.count > 1 else { return artworks }

        let measured = await measuringLocalFiles(artworks)
        let target = sunlight.targetBrightness

        return measured
            .enumerated()
            .sorted { left, right in
                let a = left.element.lightness.map { abs($0 - target) }
                let b = right.element.lightness.map { abs($0 - target) }
                switch (a, b) {
                case let (a?, b?) where a != b: return a < b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return left.offset < right.offset
                }
            }
            .map(\.element)
    }

    /// Measures the photos that are already files on this Mac.
    ///
    /// Only those: measuring a remote photo would mean downloading it first,
    /// and downloading a batch to choose one from it is exactly the cost this
    /// feature is built to avoid. Unsplash and Wallhaven send a dominant colour
    /// with the search result instead, so theirs is already known; APOD sends
    /// nothing and is measured after the download it was going to do anyway.
    ///
    /// Capped, and off the main thread: a folder draw is a shortlist, but the
    /// shortlist grows with the screen count and every measurement decodes a
    /// thumbnail.
    private static func measuringLocalFiles(_ artworks: [Artwork]) async -> [Artwork] {
        // Worked out here and handed over as plain positions and URLs: the
        // background task measures files and knows nothing about `Artwork`.
        let pending: [(position: Int, url: URL)] = artworks.enumerated()
            .prefix(sampleLimit)
            .compactMap { index, artwork in
                guard artwork.lightness == nil, artwork.origin.isLocalFile else { return nil }
                return (index, artwork.origin.url)
            }
        guard !pending.isEmpty else { return artworks }

        let measured = await Task.detached(priority: .utility) {
            pending.reduce(into: [Int: Double]()) { result, file in
                result[file.position] = ImageBrightness.lightness(ofFile: file.url)
            }
        }.value

        return artworks.enumerated().map { index, artwork in
            measured[index].map { artwork.withLightness($0) } ?? artwork
        }
    }

    /// How many files a folder draw is willing to measure before it stops
    /// caring which is the best fit.
    ///
    /// Measuring costs about 60 ms for a full-size JPEG with no embedded
    /// thumbnail — measured — so this is a second of background CPU once per
    /// change, and it is sized to the draw rather than guessed: the fetch adds
    /// ten candidates when the sky is being matched, so twelve covers a
    /// single-screen folder pick without ever leaving files unmeasured.
    private static let sampleLimit = 12

    /// Fills in a photo's brightness from the file itself.
    ///
    /// The file is the truth about how light a photo is; a dominant colour is
    /// only a good enough guess to have ranked the batch by. Writing the
    /// measured value back into the index is what lets the cache fallback rank
    /// too.
    static func measuring(_ artwork: Artwork, at url: URL) async -> Artwork {
        let measured = await Task.detached(priority: .utility) {
            ImageBrightness.lightness(ofFile: url)
        }.value
        return artwork.withLightness(measured)
    }
}
