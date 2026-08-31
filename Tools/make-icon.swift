// Renders the Heed app icon at a given size. Run: swift Tools/make-icon.swift <size> <out.png>
//
// A Borg cube as a bold wireframe: the six-sided silhouette plus the three edges meeting at the
// centre, on a dark tile. Nothing inside them -- an earlier version had shaded faces, a surface grid
// and lit panels, which looked right at 1024px and turned into an unreadable dark smudge in the
// Accessibility list, where the icon is actually seen at about 40px.
//
// The three centre edges stay because without them an isometric cube reads as a plain hexagon.
//
// Drawn in code so the whole iconset is reproducible with nothing but the system toolchain.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <size> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
let side = Double(size)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let borgGreen = rgba(0.42, 0.95, 0.38, 0.96)

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// MARK: Tile

let inset = side * 0.045
let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
// Apple's continuous-corner ratio, near enough at icon sizes.
let radius = tile.width * 0.2237

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
let backdrop = CGGradient(
    colorsSpace: space,
    colors: [rgba(0.043, 0.071, 0.055), rgba(0.012, 0.024, 0.016)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    backdrop, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: []
)
ctx.restoreGState()

// MARK: Small sizes
//
// Below 32px an isometric wireframe has about ten pixels to work with and blurs into a green blob.
// So the mark changes rather than shrinking: the cube seen head-on, still outline only, snapped to
// whole pixels so the stroke stays crisp instead of straddling two rows.
if size < 32 {
    let box = (side * 0.56).rounded()
    let origin = ((side - box) / 2).rounded()
    ctx.setStrokeColor(borgGreen)
    ctx.setLineWidth(2)
    ctx.stroke(CGRect(x: origin, y: origin, width: box, height: box).insetBy(dx: 1, dy: 1))

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else { exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
    exit(0)
}

// MARK: Cube

let r = side * 0.30
let hw = r * 0.8660254   // cos 30
let hh = r * 0.5
func point(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: side / 2 + x, y: side / 2 + y)
}

let vTop = point(0, r)
let vRight = point(hw, hh)
let vBottomRight = point(hw, -hh)
let vBottom = point(0, -r)
let vBottomLeft = point(-hw, -hh)
let vLeft = point(-hw, hh)
let vCentre = point(0, 0)

ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.setStrokeColor(borgGreen)
// Bold, and it has to stay at least a pixel wide once the icon is 16px across.
ctx.setLineWidth(max(side * 0.042, 1.2))

ctx.beginPath()
ctx.move(to: vTop)
for p in [vRight, vBottomRight, vBottom, vBottomLeft, vLeft] { ctx.addLine(to: p) }
ctx.closePath()
ctx.strokePath()

// The centre is the cube's nearest corner, so its three edges run to the left and right vertices
// (the near edges of the top face) and straight down (the vertical front edge). Drawing one of them
// to the top vertex instead splits the top face with a diagonal that does not exist and loses the
// front edge -- which shaded faces hid, and a wireframe does not.
ctx.beginPath()
for p in [vLeft, vRight, vBottom] {
    ctx.move(to: vCentre)
    ctx.addLine(to: p)
}
ctx.strokePath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        out as CFURL, UTType.png.identifier as CFString, 1, nil
      )
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
