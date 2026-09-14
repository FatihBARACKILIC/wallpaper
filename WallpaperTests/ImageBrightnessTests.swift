import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Wallpaper

/// How light a photo is, which is what the sunlight matching sorts on.
///
/// The scale matters as much as the arithmetic: it has to put mid-grey near
/// the middle, because "a bit darker than noon" is a real instruction and a
/// linear luminance scale would answer it with 0.22.
@Suite("Image brightness")
struct ImageBrightnessTests {

    @Test("Black, white and the greys in between")
    func endsAndMiddle() throws {
        #expect(try #require(ImageBrightness.lightness(ofHex: "#000000")) == 0)
        #expect(try #require(ImageBrightness.lightness(ofHex: "#ffffff")) == 1)

        // 50% sRGB grey. On the L* scale a person would call this half-way,
        // which is the whole reason L* is used: its linear luminance is 0.216,
        // and sorting on that would call mid-grey a dark photo.
        let midGrey = try #require(ImageBrightness.lightness(ofHex: "#808080"))
        #expect(abs(midGrey - 0.533) < 0.01)
    }

    @Test("Spellings the providers actually send")
    func parsing() {
        // Wallhaven writes a leading hash; three-digit shorthand costs nothing.
        #expect(ImageBrightness.lightness(ofHex: "#424153") != nil)
        #expect(ImageBrightness.lightness(ofHex: "424153") != nil)
        #expect(ImageBrightness.lightness(ofHex: "#fff") == 1)

        #expect(ImageBrightness.lightness(ofHex: "") == nil)
        #expect(ImageBrightness.lightness(ofHex: "rebeccapurple") == nil)
        #expect(ImageBrightness.lightness(ofHex: "#12345") == nil)
    }

    @Test("Green reads brighter than blue at the same hex distance")
    func channelsAreWeightedLikeTheEye() throws {
        let green = try #require(ImageBrightness.lightness(ofHex: "#00ff00"))
        let red = try #require(ImageBrightness.lightness(ofHex: "#ff0000"))
        let blue = try #require(ImageBrightness.lightness(ofHex: "#0000ff"))
        #expect(green > red)
        #expect(red > blue)
    }

    @Test("A palette leans on the colour listed first")
    func paletteWeighting() throws {
        // Wallhaven orders its five by prominence and says nothing about how
        // much of the image each covers, so the order is the only signal.
        // Weights 5,4,3,2,1: three blacks first leaves 3/15 of the weight on
        // white. Averaged in L*, that reads as 0.2 — a dark wallpaper. Averaged
        // in linear light it would come out at 0.52, which is the mistake this
        // pins.
        let mostlyDark = try #require(
            ImageBrightness.lightness(ofPalette: ["#000000", "#000000", "#000000", "#ffffff", "#ffffff"])
        )
        let mostlyLight = try #require(
            ImageBrightness.lightness(ofPalette: ["#ffffff", "#ffffff", "#ffffff", "#000000", "#000000"])
        )
        #expect(abs(mostlyDark - 0.2) < 0.001)
        #expect(abs(mostlyLight - 0.8) < 0.001)

        // A palette of one is just that colour.
        #expect(try #require(ImageBrightness.lightness(ofPalette: ["#ffffff"])) == 1)
        #expect(ImageBrightness.lightness(ofPalette: []) == nil)
        // Junk entries are skipped rather than poisoning the average.
        #expect(try #require(ImageBrightness.lightness(ofPalette: ["not a colour", "#ffffff"])) == 1)
    }

    @Test("A file on disk is measured, and an unreadable one says so")
    func measuringFiles() throws {
        let folder = TemporaryFolder()
        defer { folder.cleanUp() }

        let black = folder.url.appending(path: "black.png")
        let white = folder.url.appending(path: "white.png")
        writePNG(grey: 0, to: black)
        writePNG(grey: 255, to: white)

        #expect(try #require(ImageBrightness.lightness(ofFile: black)) < 0.01)
        #expect(try #require(ImageBrightness.lightness(ofFile: white)) > 0.99)

        // The bytes a folder scan can hand over are not always an image: the
        // extension is all `ImageFile` checks.
        #expect(ImageBrightness.lightness(ofFile: folder.write("broken.jpg")) == nil)
        #expect(ImageBrightness.lightness(ofFile: folder.url.appending(path: "gone.png")) == nil)
    }
}
