// Renders the Synapse app icon. Usage: swift Scripts/make_icon.swift <output.png>
// Light tile with a glossy S-shaped signal path and a spark where its two halves meet.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)   // y grows downward

let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func lighter(_ c: CGColor, _ t: CGFloat) -> CGColor {
    let p = c.components!
    return CGColor(red: p[0] + (1 - p[0]) * t, green: p[1] + (1 - p[1]) * t, blue: p[2] + (1 - p[2]) * t, alpha: 1)
}
func darker(_ c: CGColor, _ t: CGFloat) -> CGColor {
    let p = c.components!
    return CGColor(red: p[0] * (1 - t), green: p[1] * (1 - t), blue: p[2] * (1 - t), alpha: 1)
}

// Tile (macOS grid: 824 px tile inside a 1024 canvas)
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let w = tile.width
let tilePath = CGPath(roundedRect: tile, cornerWidth: w * 0.225, cornerHeight: w * 0.225, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x000000, 0.22))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0xF4F4F6)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xE9E9EE)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
ctx.restoreGState()
ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0x000000, 0.06)); ctx.setLineWidth(2); ctx.strokePath()

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + w * x, y: tile.minY + w * y) }

/// Draws a glossy candy-like shape.
func glossy(_ path: CGPath, _ base: CGColor) {
    let box = path.boundingBox
    // colored soft shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: w * 0.018), blur: w * 0.035, color: darker(base, 0.1).copy(alpha: 0.45)!)
    ctx.addPath(path); ctx.setFillColor(base); ctx.fillPath()
    ctx.restoreGState()
    // body gradient
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let body = CGGradient(colorsSpace: space, colors: [lighter(base, 0.28), base, darker(base, 0.08)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
    // top gloss
    let gloss = CGRect(x: box.minX + box.width * 0.12, y: box.minY + box.height * 0.06, width: box.width * 0.76, height: box.height * 0.42)
    let glossPath = CGPath(roundedRect: gloss, cornerWidth: min(gloss.width, gloss.height) / 2, cornerHeight: min(gloss.width, gloss.height) / 2, transform: nil)
    ctx.addPath(glossPath); ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: gloss.midX, y: gloss.minY), end: CGPoint(x: gloss.midX, y: gloss.maxY), options: [])
    ctx.restoreGState()
    // crisp rim
    ctx.addPath(path); ctx.setStrokeColor(darker(base, 0.12).copy(alpha: 0.35)!); ctx.setLineWidth(w * 0.006); ctx.strokePath()
}

func capsule(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil)
}

let blue = rgb(0x3D8BFF), violet = rgb(0xA15CF6), coral = rgb(0xFF6B5B), teal = rgb(0x14C8C0)

// An S-shaped signal path: two glossy arcs and a spark where they meet.
func arcTube(_ center: CGPoint, _ radius: CGFloat, _ start: CGFloat, _ end: CGFloat, clockwise: Bool, _ c: CGColor) {
    let p = CGMutablePath()
    p.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    glossy(p.copy(strokingWithWidth: w * 0.12, lineCap: .round, lineJoin: .round, miterLimit: 1), c)
}
arcTube(P(0.5, 0.36), w * 0.14, -.pi * 0.08, .pi * 0.62, clockwise: true, blue)
arcTube(P(0.5, 0.64), w * 0.14, -.pi * 0.38, .pi * 0.92, clockwise: false, violet)
let r = w * 0.048
let sp = P(0.5, 0.5)
glossy(CGPath(ellipseIn: CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2), transform: nil), coral)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
