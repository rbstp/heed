// Renders the Heed app icon at a given size. Run: swift run heed-icon <size> <out.png>

import AppKit
import HeedCore

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]), size > 0 else {
    FileHandle.standardError.write(Data("usage: heed-icon <size> <out.png>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
let side = CGFloat(size)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
rep.size = NSSize(width: side, height: side)   // one point per pixel
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// Apple's continuous-corner ratio, near enough at icon sizes.
let inset = side * 0.045
let tile = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let radius = tile.width * 0.2237
let backdrop = NSGradient(
    starting: NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.19, alpha: 1),
    ending: NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
)!
backdrop.draw(in: NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius), angle: -90)

// The mark reaches along the axes and leaves the corners empty, so it needs more of the tile than
// a square glyph would.
let glyph = side * 0.66
context.cgContext.translateBy(x: (side - glyph) / 2, y: (side - glyph) / 2)
context.cgContext.addPath(glyphPath(.attending, side: glyph))
context.cgContext.setFillColor(.white)
context.cgContext.fillPath()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: out)
