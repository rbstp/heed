// Renders the Heed app icon at a given size. Run: swift Tools/make-icon.swift <size> <out.png>
//
// A Borg cube: isometric, industrial, restrained. The cube reads as a window at small sizes and as
// greebled machinery at large ones, and green is doing the thematic work rather than any ornament.
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

ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)

// MARK: Tile

// Apple's continuous-corner ratio, near enough at icon sizes.
let inset = side * 0.045
let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let radius = tile.width * 0.2237
let tilePath = CGPath(
    roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil
)

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let backdrop = CGGradient(
    colorsSpace: space,
    colors: [rgba(0.055, 0.086, 0.070), rgba(0.014, 0.024, 0.019)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    backdrop,
    start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY),
    options: []
)
ctx.restoreGState()

// MARK: Small sizes
//
// Below 32px an isometric cube has about nine pixels to work with and collapses into a green ring.
// So the mark changes rather than shrinking: the cube seen head-on, which is the same object and
// stays crisp. Coordinates are snapped to whole pixels to avoid a blurred grid.
if size < 32 {
    let box = (Double(size) * 0.60).rounded()
    let originX = ((side - box) / 2).rounded()
    let originY = ((side - box) / 2).rounded()
    let face = CGRect(x: originX, y: originY, width: box, height: box)

    ctx.setFillColor(rgba(0.071, 0.104, 0.086))
    ctx.fill(face)

    ctx.setStrokeColor(rgba(0.478, 0.937, 0.404, 0.55))
    ctx.setLineWidth(1)
    let step = (box / 3).rounded()
    ctx.beginPath()
    for k in 1..<3 {
        let offset = (step * Double(k)).rounded()
        ctx.move(to: CGPoint(x: face.minX + offset, y: face.minY))
        ctx.addLine(to: CGPoint(x: face.minX + offset, y: face.maxY))
        ctx.move(to: CGPoint(x: face.minX, y: face.minY + offset))
        ctx.addLine(to: CGPoint(x: face.maxX, y: face.minY + offset))
    }
    ctx.strokePath()

    ctx.setStrokeColor(rgba(0.478, 0.937, 0.404, 0.9))
    ctx.setLineWidth(1)
    ctx.stroke(face.insetBy(dx: 0.5, dy: 0.5))

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else { exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
    exit(0)
}

// MARK: Cube geometry

let cx = side / 2, cy = side / 2
let r = side * 0.285
let hw = r * 0.8660254   // cos 30
let hh = r * 0.5

func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: cx + x, y: cy + y) }

let vTop = point(0, r)
let vRight = point(hw, hh)
let vBottomRight = point(hw, -hh)
let vBottom = point(0, -r)
let vBottomLeft = point(-hw, -hh)
let vLeft = point(-hw, hh)
let vCenter = point(0, 0)

func fill(_ pts: [CGPoint], _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.beginPath()
    ctx.move(to: pts[0])
    for p in pts.dropFirst() { ctx.addLine(to: p) }
    ctx.closePath()
    ctx.fillPath()
}

// Top lit, right mid, left darkest: a single light source, no drama. The spread between the three
// is what makes the cube read at 16px, where the edge strokes all but disappear -- so it carries the
// form on its own rather than leaning on them.
fill([vLeft, vTop, vRight, vCenter], rgba(0.157, 0.220, 0.184))
fill([vCenter, vRight, vBottomRight, vBottom], rgba(0.071, 0.104, 0.086))
fill([vCenter, vLeft, vBottomLeft, vBottom], rgba(0.027, 0.043, 0.035))

// MARK: Surface detail

/// Draws a grid across a parallelogram face, plus a few filled cells as lit panels.
func greeble(
    origin: CGPoint, u: CGVector, v: CGVector,
    divisions: Int, lit: [(Int, Int)], lineAlpha: Double, panelAlpha: Double
) {
    let n = Double(divisions)
    func at(_ a: Double, _ b: Double) -> CGPoint {
        CGPoint(x: origin.x + u.dx * a + v.dx * b, y: origin.y + u.dy * a + v.dy * b)
    }

    for (i, j) in lit {
        let a0 = Double(i) / n, a1 = Double(i + 1) / n
        let b0 = Double(j) / n, b1 = Double(j + 1) / n
        let pad = 0.13 / n
        fill(
            [at(a0 + pad, b0 + pad), at(a1 - pad, b0 + pad),
             at(a1 - pad, b1 - pad), at(a0 + pad, b1 - pad)],
            rgba(0.478, 0.937, 0.404, panelAlpha)
        )
    }

    ctx.setStrokeColor(rgba(0.478, 0.937, 0.404, lineAlpha))
    ctx.setLineWidth(max(side * 0.0035, 0.6))
    for k in 1..<divisions {
        let t = Double(k) / n
        ctx.move(to: at(t, 0)); ctx.addLine(to: at(t, 1))
        ctx.move(to: at(0, t)); ctx.addLine(to: at(1, t))
    }
    ctx.strokePath()
}

struct CGVector { let dx: Double; let dy: Double }

// Detail is dropped at the sizes where it would only turn into noise.
if size >= 64 {
    let divisions = size >= 256 ? 4 : 3
    greeble(
        origin: vLeft,
        u: CGVector(dx: hw, dy: hh), v: CGVector(dx: hw, dy: -hh),
        divisions: divisions, lit: divisions == 4 ? [(2, 1)] : [(1, 1)],
        lineAlpha: 0.20, panelAlpha: 0.85
    )
    greeble(
        origin: vCenter,
        u: CGVector(dx: hw, dy: hh), v: CGVector(dx: 0, dy: -r),
        divisions: divisions, lit: divisions == 4 ? [(1, 2), (3, 0)] : [(0, 1)],
        lineAlpha: 0.16, panelAlpha: 0.55
    )
    greeble(
        origin: vCenter,
        u: CGVector(dx: -hw, dy: hh), v: CGVector(dx: 0, dy: -r),
        divisions: divisions, lit: [],
        lineAlpha: 0.10, panelAlpha: 0.3
    )
}

// MARK: Silhouette

// Strokes carry proportionally more of the shape the smaller the icon gets.
let small = size < 64
ctx.setStrokeColor(rgba(0.478, 0.937, 0.404, small ? 0.58 : 0.38))
ctx.setLineWidth(max(side * 0.006, 0.9))
ctx.beginPath()
ctx.move(to: vTop)
for p in [vRight, vBottomRight, vBottom, vBottomLeft, vLeft] { ctx.addLine(to: p) }
ctx.closePath()
ctx.strokePath()

// The three interior edges, fainter, so the cube reads as solid rather than as a hexagon.
ctx.setStrokeColor(rgba(0.478, 0.937, 0.404, small ? 0.46 : 0.16))
ctx.setLineWidth(max(side * 0.004, 0.7))
ctx.beginPath()
for p in [vTop, vRight, vLeft] { ctx.move(to: vCenter); ctx.addLine(to: p) }
ctx.strokePath()

// MARK: Tile edge

// Below 32px the tile edge is just noise competing with the cube.
if size >= 32 {
    ctx.addPath(tilePath)
    ctx.setStrokeColor(rgba(0.478, 0.937, 0.404, 0.13))
    ctx.setLineWidth(max(side * 0.005, 0.7))
    ctx.strokePath()
}

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
