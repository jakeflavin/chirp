// Makes the Beta app icon: the bird from the normal icon, unchanged, on a blueprint.
//
//   swift Scripts/make-beta-icon.swift [preview folder]
//
// Reads App/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png, lifts the bird and its wire off
// the cream background, and writes every size into AppIconBeta.appiconset beside it. With a folder
// given, it also writes icon-1024.png and icon-128.png there to look at. Run it from the repo's root.
// Nothing here leaves the Mac. To stop shipping a Beta icon, delete AppIconBeta.appiconset and the
// BETA lines in project.yml.

import AppKit
import CoreGraphics
import Foundation

let assets = "App/Resources/Assets.xcassets"
let source = "\(assets)/AppIcon.appiconset/icon_1024.png"
let outSet = "\(assets)/AppIconBeta.appiconset"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

guard let image = NSImage(contentsOfFile: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Cannot read \(source)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: The source's pixels

let n = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue

func bitmap(_ side: Int) -> CGContext {
    CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: info)!
}

let src = bitmap(n)
src.interpolationQuality = .high
src.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
let px = src.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)  // row 0 is the top row

struct RGB { var r, g, b: Double }
func colour(_ x: Int, _ y: Int) -> RGB {
    let i = (y * n + x) * 4
    return RGB(r: Double(px[i]), g: Double(px[i + 1]), b: Double(px[i + 2]))
}
func opaque(_ x: Int, _ y: Int) -> Bool { px[(y * n + x) * 4 + 3] == 255 }
func apart(_ a: RGB, _ b: RGB) -> Double { max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) }

// MARK: Which pixels are the cream background

// The background is a smooth top-to-bottom gradient, so next-door background pixels are almost the
// same colour. Spread from a point that is certainly background across such pixels.
var isBackground = [Bool](repeating: false, count: n * n)
var queue = [(n / 2, 150)]
isBackground[150 * n + n / 2] = true
var head = 0
while head < queue.count {
    let (x, y) = queue[head]
    head += 1
    let here = colour(x, y)
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, ny >= 0, nx < n, ny < n, !isBackground[ny * n + nx], opaque(nx, ny) else { continue }
        if apart(colour(nx, ny), here) <= 2 {
            isBackground[ny * n + nx] = true
            queue.append((nx, ny))
        }
    }
}

// The background's colour on each row: the middle value of the row's background pixels.
var rowColour = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: n)
var lastSeen: RGB?
for y in 0..<n {
    var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
    for x in 0..<n where isBackground[y * n + x] {
        let c = colour(x, y)
        rs.append(c.r); gs.append(c.g); bs.append(c.b)
    }
    if !rs.isEmpty {
        rs.sort(); gs.sort(); bs.sort()
        lastSeen = RGB(r: rs[rs.count / 2], g: gs[gs.count / 2], b: bs[bs.count / 2])
    }
    if let lastSeen { rowColour[y] = lastSeen }
}

// Cream shut in by the art (between the legs) is background too: it matches its row's colour.
for y in 0..<n {
    for x in 0..<n where opaque(x, y) && !isBackground[y * n + x] && apart(colour(x, y), rowColour[y]) <= 3 {
        isBackground[y * n + x] = true
    }
}

// MARK: The bird and the wire as their own layers

// A pixel is art when it is inside the icon's shape and not background. Art within a few pixels of the
// background is an edge: part art, part cream. Its strength is worked out from the solid colour just
// inside it, so no cream fringe comes along.
let reach = 2
var solid = [Bool](repeating: false, count: n * n)
var edge = [Bool](repeating: false, count: n * n)
for y in 0..<n {
    for x in 0..<n where opaque(x, y) && !isBackground[y * n + x] {
        var near = false
        search: for dy in -reach...reach {
            for dx in -reach...reach {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < n, ny < n, isBackground[ny * n + nx] { near = true; break search }
            }
        }
        if near { edge[y * n + x] = true } else { solid[y * n + x] = true }
    }
}

// Each edge pixel takes the colour of the nearest solid pixel.
var inside = [RGB?](repeating: nil, count: n * n)
var frontier: [(Int, Int)] = []
for y in 0..<n { for x in 0..<n where solid[y * n + x] { inside[y * n + x] = colour(x, y); frontier.append((x, y)) } }
head = 0
while head < frontier.count {
    let (x, y) = frontier[head]
    head += 1
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, ny >= 0, nx < n, ny < n, edge[ny * n + nx], inside[ny * n + nx] == nil else { continue }
        inside[ny * n + nx] = inside[y * n + x]
        frontier.append((nx, ny))
    }
}

let bird = bitmap(n), wire = bitmap(n)
let birdPx = bird.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
let wirePx = wire.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
/// The wire is the dark line under the bird; the only other dark thing, the eye, is well above it.
func isWire(_ c: RGB, _ y: Int) -> Bool { y > n * 6 / 10 && c.r < 90 && c.g < 90 && c.b < 110 }

for y in 0..<n {
    for x in 0..<n {
        let i = y * n + x
        guard solid[i] || edge[i] else { continue }
        var c = colour(x, y)
        var alpha = 1.0
        if edge[i], let f = inside[i] {
            let bg = rowColour[y]
            let d = RGB(r: f.r - bg.r, g: f.g - bg.g, b: f.b - bg.b)
            let length = d.r * d.r + d.g * d.g + d.b * d.b
            if length > 400 {
                alpha = ((c.r - bg.r) * d.r + (c.g - bg.g) * d.g + (c.b - bg.b) * d.b) / length
                alpha = max(0, min(1, alpha))
                c = f
            }
        }
        let out = isWire(c, y) ? wirePx : birdPx
        out[i * 4] = UInt8((c.r * alpha).rounded())
        out[i * 4 + 1] = UInt8((c.g * alpha).rounded())
        out[i * 4 + 2] = UInt8((c.b * alpha).rounded())
        out[i * 4 + 3] = UInt8((255 * alpha).rounded())
    }
}
let birdImage = bird.makeImage()!
let wireImage = wire.makeImage()!

// The icon's rounded shape, taken from the source so the Beta icon has exactly the same outline.
let shape = bitmap(n)
let shapePx = shape.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
for i in 0..<(n * n) {
    let a = px[i * 4 + 3]
    shapePx[i * 4] = a; shapePx[i * 4 + 1] = a; shapePx[i * 4 + 2] = a; shapePx[i * 4 + 3] = a
}
let shapeImage = shape.makeImage()!

// MARK: Drawing one size

func white(_ alpha: Double) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

func render(_ side: Int) -> CGImage {
    let ctx = bitmap(side)
    ctx.interpolationQuality = .high
    let whole = CGRect(x: 0, y: 0, width: side, height: side)
    // Everything below is laid out on the 1024 grid with the top at y = 0.
    ctx.translateBy(x: 0, y: CGFloat(side))
    ctx.scaleBy(x: CGFloat(side) / 1024, y: -CGFloat(side) / 1024)
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)

    // Blueprint blue, a little lighter at the top.
    let blues = [CGColor(srgbRed: 0.165, green: 0.416, blue: 0.741, alpha: 1), CGColor(srgbRed: 0.094, green: 0.302, blue: 0.616, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: blues as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // The drafting grid: fine squares, a heavier line every fourth. Small sizes keep only the heavy lines.
    func lines(every step: Int, width: CGFloat, alpha: Double) {
        ctx.setStrokeColor(white(alpha))
        ctx.setLineWidth(width)
        var offset = 0
        while offset < 512 {
            for p in Set([512 + offset, 512 - offset]) {
                ctx.move(to: CGPoint(x: CGFloat(p), y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(p), y: 1024))
                ctx.move(to: CGPoint(x: 0, y: CGFloat(p))); ctx.addLine(to: CGPoint(x: 1024, y: CGFloat(p)))
            }
            offset += step
        }
        ctx.strokePath()
    }
    if side >= 128 { lines(every: 32, width: 2, alpha: 0.11) }
    lines(every: 128, width: side >= 128 ? 3.5 : 10, alpha: side >= 128 ? 0.24 : 0.16)

    // Faint drafting marks: a construction circle round the bird with its centre lines, and a
    // measured line under the wire.
    if side >= 128 {
        let centre = CGPoint(x: 502, y: 476)
        ctx.setStrokeColor(white(0.34))
        ctx.setLineWidth(3)
        ctx.setLineDash(phase: 0, lengths: [16, 11])
        ctx.addEllipse(in: CGRect(x: centre.x - 226, y: centre.y - 226, width: 452, height: 452))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [34, 9, 6, 9])
        ctx.move(to: CGPoint(x: centre.x - 270, y: centre.y)); ctx.addLine(to: CGPoint(x: centre.x + 270, y: centre.y))
        ctx.move(to: CGPoint(x: centre.x, y: centre.y - 270)); ctx.addLine(to: CGPoint(x: centre.x, y: centre.y + 190))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        let y: CGFloat = 800, left: CGFloat = 148, right: CGFloat = 876
        ctx.setStrokeColor(white(0.42))
        ctx.setFillColor(white(0.42))
        ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: left, y: y)); ctx.addLine(to: CGPoint(x: right, y: y))
        for x in [left, right] { ctx.move(to: CGPoint(x: x, y: y - 22)); ctx.addLine(to: CGPoint(x: x, y: y + 22)) }
        ctx.strokePath()
        for (x, way) in [(left, CGFloat(1)), (right, CGFloat(-1))] {
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + way * 26, y: y - 8))
            ctx.addLine(to: CGPoint(x: x + way * 26, y: y + 8))
            ctx.closePath()
        }
        ctx.fillPath()
    }

    // The wire as a white drafting line, then the bird exactly as it is in the normal icon.
    // Images are stored top row first; drawing in this flipped space needs them turned back over.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.saveGState()
    ctx.clip(to: full, mask: wireImage)
    ctx.setFillColor(white(0.96))
    ctx.fill(full)
    ctx.restoreGState()
    ctx.draw(birdImage, in: full)
    ctx.restoreGState()

    // Cut to the icon's shape.
    let cut = bitmap(side)
    cut.interpolationQuality = .high
    cut.clip(to: whole, mask: shapeImage)
    cut.draw(ctx.makeImage()!, in: whole)
    return cut.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// MARK: Output

let files = FileManager.default
try? files.createDirectory(atPath: outSet, withIntermediateDirectories: true)
try? files.removeItem(atPath: "\(outSet)/Contents.json")
try! files.copyItem(atPath: "\(assets)/AppIcon.appiconset/Contents.json", toPath: "\(outSet)/Contents.json")
for side in sizes { write(render(side), to: "\(outSet)/icon_\(side).png") }

if CommandLine.arguments.count > 1 {
    let folder = CommandLine.arguments[1]
    try? files.createDirectory(atPath: folder, withIntermediateDirectories: true)
    write(render(1024), to: "\(folder)/icon-1024.png")
    write(render(128), to: "\(folder)/icon-128.png")
}
print("Wrote \(sizes.count) sizes to \(outSet)")
