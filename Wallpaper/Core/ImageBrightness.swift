import Foundation
import ImageIO

/// How light or dark a photo is, on a 0…1 scale a human would agree with.
///
/// Two ways in, because the providers differ in what they will tell you for
/// free. Unsplash and Wallhaven both hand back the dominant colours of every
/// photo *in the search response*, so a whole batch can be ranked before a
/// single byte is downloaded — which is the only reason this feature costs no
/// extra requests. APOD and a folder on this Mac say nothing, so those are
/// measured from the file.
///
/// The scale is CIE L\*, not raw luminance, and the averaging happens *in* L\*
/// rather than in linear light. Both halves of that matter. L\* is the scale
/// that matches what a person calls bright — mid-grey lands near 0.5 instead of
/// the 0.22 linear luminance gives it — and averaging in it keeps a mostly-dark
/// photo dark: mean linear luminance is dominated by highlights, so a night
/// scene with a bright moon in it would come out middling and get picked for
/// noon.
nonisolated enum ImageBrightness {

    /// Lightness of a single `#rrggbb` colour, or `nil` if it will not parse.
    static func lightness(ofHex hex: String) -> Double? {
        guard let channels = channels(ofHex: hex) else { return nil }
        return lightness(red: channels.red, green: channels.green, blue: channels.blue)
    }

    /// Lightness of a palette, weighted towards the colours listed first.
    ///
    /// Wallhaven returns its five most prominent colours in order but says
    /// nothing about how much of the image each covers, so the order is the
    /// only signal there is: 5, 4, 3, 2, 1.
    static func lightness(ofPalette hexes: [String]) -> Double? {
        var total = 0.0
        var weightSum = 0.0
        for (index, hex) in hexes.enumerated() {
            guard let value = lightness(ofHex: hex) else { continue }
            let weight = Double(max(1, hexes.count - index))
            total += value * weight
            weightSum += weight
        }
        guard weightSum > 0 else { return nil }
        return total / weightSum
    }

    /// Lightness of an image file.
    ///
    /// Reads a 32×32 thumbnail rather than the image: ImageIO will take an
    /// embedded one when the file has it and downsample while decoding when it
    /// does not, so a 50 MB original never lands in memory. 1024 pixels is
    /// ample — this is one number, not a histogram.
    ///
    /// Not cheap enough to call on a whole folder: it is for a shortlist that
    /// has already been narrowed by everything else.
    static func lightness(ofFile url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary)
        else { return nil }

        return lightness(of: thumbnail)
    }

    // MARK: - Pixels

    private static func lightness(of image: CGImage) -> Double? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += lightness(
                red: Double(pixels[index]) / 255,
                green: Double(pixels[index + 1]) / 255,
                blue: Double(pixels[index + 2]) / 255
            )
        }

        return total / Double(width * height)
    }

    // MARK: - Colour maths

    private static func channels(ofHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }

        // Both spellings turn up: Wallhaven writes #424153, and a three-digit
        // shorthand is legal CSS that costs nothing to accept.
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }

        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// CIE L\* of one sRGB colour, scaled to 0…1.
    private static func lightness(red: Double, green: Double, blue: Double) -> Double {
        // Gamma-decoded, and weighted the way the eye weights the channels.
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)

        let clamped = min(1, max(0, luminance))
        let star = clamped > 0.008856
            ? 116 * pow(clamped, 1.0 / 3) - 16
            : 903.3 * clamped
        return min(1, max(0, star / 100))
    }
}
