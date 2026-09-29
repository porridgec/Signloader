#!/usr/bin/env swift
//
// Generates the AppIcon.iconset from vector drawing code, so the icon is
// reproducible from source rather than an opaque binary.
//
//   swift Tools/make-icon.swift <output.iconset>
//
// Drawing is pure CoreGraphics: NSGraphicsContext mutates the CTM when handed
// an unflipped context, which silently blows up the coordinate space, so it is
// avoided entirely.
import AppKit
import Foundation

// MARK: - Geometry

/// A rasterised SF Symbol plus the tight bounds of its visible ink.
struct SymbolArt {
    let image: CGImage
    let ink: CGRect

    var size: CGSize { CGSize(width: CGFloat(image.width), height: CGFloat(image.height)) }

    /// Draw so the *ink* (not the padded box) is `inkSize` across and centred on
    /// `centre`. This is what makes the glyph actually look centred.
    func drawCentred(on ctx: CGContext, inkSize: CGFloat, centre: CGPoint, shadow: Bool) {
        let scale = inkSize / max(ink.width, ink.height)
        let width = size.width * scale
        let height = size.height * scale
        // Solve for the destination origin that puts the ink centre on `centre`.
        let origin = CGPoint(
            x: centre.x - (ink.midX / size.width) * width,
            y: centre.y - (ink.midY / size.height) * height
        )
        let rect = CGRect(origin: origin, size: CGSize(width: width, height: height))

        ctx.saveGState()
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20,
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)
        }
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}

/// Superellipse (squircle) path — the shape macOS uses for app icons.
/// `exponent` 5 matches Apple's Big Sur icon grid.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5, steps: Int = 720) -> CGPath {
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let p = 2 / exponent

    let path = CGMutablePath()
    for i in 0...steps {
        let t = 2 * .pi * CGFloat(i) / CGFloat(steps)
        let cosT = cos(t), sinT = sin(t)
        let x = cx + a * copysign(pow(abs(cosT), p), cosT)
        let y = cy + b * copysign(pow(abs(sinT), p), sinT)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ colors: [NSColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors.map(\.cgColor) as CFArray,
        locations: locations
    )!
}

/// Render an SF Symbol as a solid-colour image, reporting its ink bounds.
func symbolImage(
    _ name: String,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
) -> SymbolArt? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config),
        let baseCG = base.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }

    guard let ctx = CGContext(
        data: nil,
        width: baseCG.width,
        height: baseCG.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Fill the symbol's alpha with a flat colour.
    ctx.setFillColor(color.cgColor)
    ctx.addRect(CGRect(x: 0, y: 0, width: baseCG.width, height: baseCG.height))
    ctx.fillPath()
    ctx.setBlendMode(.destinationIn)
    ctx.draw(baseCG, in: CGRect(x: 0, y: 0, width: baseCG.width, height: baseCG.height))
    ctx.setBlendMode(.normal)
    guard let image = ctx.makeImage() else { return nil }
    let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    return SymbolArt(image: image, ink: alphaBounds(of: image) ?? full)
}

/// Tight bounding box of everything with alpha, so callers can align the visible
/// ink rather than the padded symbol box (SF Symbols are never ink-centred).
private func alphaBounds(of image: CGImage) -> CGRect? {
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        let row = y * w * 4
        for x in 0..<w where buffer[row + x * 4 + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

// MARK: - Drawing

/// Draws the icon at `pixels` square.
///
/// Everything is authored in a 1024-unit design space; the CTM is scaled once up
/// front so no geometry below has to think about the output size.
func drawIcon(pixels: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let body = canvas.insetBy(dx: 46, dy: 46)
    let bodyPath = squirclePath(in: body)

    // Drop shadow behind the squircle.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12),
        blur: 36,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(bodyPath)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill + a soft sheen that fades out downward. A filled ellipse
    // would leave a visible hard edge across the body.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        linearGradient(
            [
                NSColor(red: 0.400, green: 0.639, blue: 0.988, alpha: 1),
                NSColor(red: 0.169, green: 0.325, blue: 0.780, alpha: 1),
            ],
            locations: [0, 1]
        ),
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )
    ctx.drawLinearGradient(
        linearGradient(
            [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)],
            locations: [0, 1]
        ),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY - body.height * 0.08),
        options: []
    )
    ctx.restoreGState()

    // Signature glyph, aligned on its ink rather than its padded symbol box —
    // SF Symbols carry asymmetric internal padding, so centring the box leaves
    // the mark visibly off-centre. Rasterised at 2x the drawn size to stay crisp.
    //
    // Centred on the body, with a ~1% optical nudge up-left to balance the badge.
    let glyphInk: CGFloat = 372
    let glyphCentre = CGPoint(x: body.midX - 14, y: body.midY + 14)
    if let glyph = symbolImage("signature", size: 1024, weight: .semibold, color: .white) {
        glyph.drawCentred(on: ctx, inkSize: glyphInk, centre: glyphCentre, shadow: true)
    }

    // Verified badge, bottom-right. Sized and placed so the whole circle — plus
    // room for its drop shadow — stays inside both the squircle and the 1024
    // canvas; pushing it to the literal corner makes it overhang and get clipped.
    let radius: CGFloat = 134
    let center = CGPoint(x: body.maxX - 166, y: body.minY + 172)
    assert(center.x - radius > 0 && center.x + radius < 1024
        && center.y - radius > 0 && center.y + radius < 1024,
        "badge must stay inside the canvas")

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(
        x: center.x - radius, y: center.y - radius,
        width: radius * 2, height: radius * 2
    ))
    ctx.restoreGState()

    let inner = radius * 0.84
    ctx.setFillColor(NSColor(red: 0.149, green: 0.729, blue: 0.396, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(
        x: center.x - inner, y: center.y - inner,
        width: inner * 2, height: inner * 2
    ))

    let check = CGMutablePath()
    let s = inner * 0.94
    check.move(to: CGPoint(x: center.x - s * 0.50, y: center.y + s * 0.04))
    check.addLine(to: CGPoint(x: center.x - s * 0.13, y: center.y - s * 0.32))
    check.addLine(to: CGPoint(x: center.x + s * 0.52, y: center.y + s * 0.36))
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(inner * 0.20)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(check)
    ctx.strokePath()

    return ctx.makeImage()
}

// MARK: - Output

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"

let fm = FileManager.default
try? fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

/// The 10 renditions macOS expects inside an .iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = drawIcon(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(variant.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputPath).appendingPathComponent("\(variant.name).png")
    try png.write(to: url)
    print("  \(variant.name).png  \(variant.pixels)×\(variant.pixels)")
}
print("→ \(outputPath)")
