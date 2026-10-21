// Renders the Synapse app icon. Usage: swift Scripts/make_icon.swift <output.png>
// Dark tile with a signal arc joining two glowing nodes.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Flip so y grows downward, matching the SwiftUI logo geometry.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
let pink = color(1.0, 0.36, 0.74), violet = color(0.49, 0.36, 1.0), cyan = color(0.16, 0.80, 1.0)
let space = CGColorSpaceCreateDeviceRGB()

// macOS icon grid: 824 px tile centered in a 1024 canvas.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let w = tile.width
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + w * x, y: tile.minY + w * y) }

// Drop shadow + tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0, 0, 0, 0.35))
let tilePath = CGPath(roundedRect: tile, cornerWidth: w * 0.225, cornerHeight: w * 0.225, transform: nil)
ctx.addPath(tilePath)
ctx.setFillColor(color(0.05, 0.04, 0.14))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0.15, 0.10, 0.34), color(0.03, 0.03, 0.10)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: tile.origin, end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
// Soft glow in the middle
let glowG = CGGradient(colorsSpace: space, colors: [color(0.49, 0.36, 1.0, 0.35), color(0.49, 0.36, 1.0, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glowG, startCenter: P(0.5, 0.5), startRadius: 0, endCenter: P(0.5, 0.5), endRadius: w * 0.55, options: [])

// Signal arc
let a = P(0.27, 0.70), b = P(0.73, 0.30)
let arc = CGMutablePath()
arc.move(to: a)
arc.addCurve(to: b, control1: P(0.27, 0.26), control2: P(0.73, 0.74))
let lineG = CGGradient(colorsSpace: space, colors: [pink, violet, cyan] as CFArray, locations: [0, 0.5, 1])!

func strokeArc(width: CGFloat, blur: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: color(0.6, 0.45, 1.0, 0.9)) }
    ctx.setAlpha(alpha)
    ctx.addPath(arc)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(lineG, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
strokeArc(width: w * 0.13, blur: w * 0.06, alpha: 0.45)
strokeArc(width: w * 0.075, blur: 0, alpha: 1)

// Nodes
for (p, c, r) in [(a, pink, 0.105), (b, cyan, 0.105), (P(0.5, 0.5), color(1, 1, 1), 0.055)] as [(CGPoint, CGColor, CGFloat)] {
    let rr = w * r
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: rr * 1.6, color: c)
    ctx.setFillColor(c)
    ctx.fillEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
    ctx.restoreGState()
    ctx.setFillColor(color(1, 1, 1, 0.85))
    let ir = rr * 0.45
    ctx.fillEllipse(in: CGRect(x: p.x - ir, y: p.y - ir, width: ir * 2, height: ir * 2))
}

// Subtle top highlight
let hl = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.minY + w * 0.45), options: [])
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
