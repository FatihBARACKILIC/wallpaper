import AppKit
import SwiftUI

/// Opens where a photo came from: its page on Unsplash, its day in the APOD
/// archive, or — for a photo of the user's own — the file itself in Finder.
///
/// Icon only. It sits at the end of a list row that is already carrying the
/// photo's name, its date and up to three other buttons, so the words go in
/// the tooltip. The full "Photo by … on Unsplash" credit belongs to the photo
/// actually on screen, and the menu still gives it there.
struct SourceLink: View {
    let artwork: Artwork

    var body: some View {
        switch artwork.provider {
        case .local:
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([artwork.origin.url])
            } label: {
                Image(systemName: "folder")
            }
            .help("Show in Finder")
            // Revealing a file the user has since deleted would do nothing at
            // all, which reads as a broken button.
            .disabled(isGone)

        case .unsplash, .apod:
            if let url = artwork.sourceURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help(artwork.provider == .unsplash
                      ? "Open this photo on Unsplash"
                      : "Open this picture in the NASA APOD archive")
            }
        }
    }

    private var isGone: Bool {
        guard case .localFile(let url) = artwork.origin else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
