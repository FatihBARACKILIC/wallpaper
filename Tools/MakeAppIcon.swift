// Draws the app icon and writes every size the asset catalogue asks for.
//
// The icon is vector-drawn at each size rather than downsampled from one large
// render, so the 16 pt version stays crisp. Run it after changing the artwork:
//
//     swift Tools/MakeAppIcon.swift Wallpaper/Assets.xcassets/AppIcon.appiconset

import AppKit

/// Pixel sizes referenced by Contents.json.
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func color(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}

func drawIcon(size: Int) -> CGImage? {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons carry their own rounded shape and a little breathing room —
    // the system does not mask them.
    let inset = side * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * 185 / 1024
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Dusk sky: warm at the horizon, deep indigo overhead. The gradient starts
    // above the bottom edge so the warm band lands beside the ridge line
    // instead of behind the mountains, where it would never be seen.
    let sky = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            color(0.96, 0.66, 0.44),
            color(0.55, 0.42, 0.74),
            color(0.16, 0.20, 0.46),
        ] as CFArray,
        locations: [0, 0.45, 1]
    )!
    context.drawLinearGradient(
        sky,
        start: CGPoint(x: body.midX, y: body.minY + body.height * 0.30),
        end: CGPoint(x: body.midX, y: body.maxY),
        options: [.drawsBeforeStartLocation]
    )

    // Sun, sitting above the ridge line so it survives at 16 pt.
    let sunRadius = body.width * 0.115
    let sun = CGPoint(x: body.minX + body.width * 0.63, y: body.minY + body.height * 0.63)
    context.setFillColor(color(1.0, 0.93, 0.79))
    context.fillEllipse(in: CGRect(
        x: sun.x - sunRadius,
        y: sun.y - sunRadius,
        width: sunRadius * 2,
        height: sunRadius * 2
    ))

    /// Ridge drawn as a fraction of the body, closed along the bottom edge.
    func ridge(_ points: [(CGFloat, CGFloat)], fill: CGColor) {
        context.beginPath()
        context.move(to: CGPoint(x: body.minX, y: body.minY))
        for (x, y) in points {
            context.addLine(to: CGPoint(x: body.minX + body.width * x, y: body.minY + body.height * y))
        }
        context.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        context.closePath()
        context.setFillColor(fill)
        context.fillPath()
    }

    ridge(
        [(0, 0.40), (0.30, 0.72), (0.60, 0.36), (0.80, 0.56), (1, 0.42)],
        fill: color(0.22, 0.25, 0.44)
    )
    ridge(
        [(0, 0.20), (0.44, 0.58), (1, 0.16)],
        fill: color(0.09, 0.11, 0.23)
    )

    context.restoreGState()

    // A hairline keeps the shape defined against a dark wallpaper.
    context.addPath(shape)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    context.setLineWidth(max(1, side / 256))
    context.strokePath()

    return context.makeImage()
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1])

for size in sizes {
    guard let image = drawIcon(size: size) else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: destination.appendingPathComponent("icon-\(size).png"))
    print("icon-\(size).png")
}
