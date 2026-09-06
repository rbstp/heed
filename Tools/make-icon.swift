// Renders the Heed app icon at a given size. Run: swift Tools/make-icon.swift <size> <out.png>
//
// The same SF Symbol the menu bar item shows, white on a dark tile, so the two match. Drawn in code
// so the whole iconset is reproducible with nothing but the system toolchain.

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]), size > 0 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <size> <out.png>\n".utf8))
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

let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .regular)
    .applying(.init(paletteColors: [.white]))
let name = "cursorarrow.motionlines"
guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration)
else { exit(1) }
symbol.isTemplate = false
let glyph = symbol.size
symbol.draw(in: NSRect(x: (side - glyph.width) / 2, y: (side - glyph.height) / 2,
                       width: glyph.width, height: glyph.height))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: out)
