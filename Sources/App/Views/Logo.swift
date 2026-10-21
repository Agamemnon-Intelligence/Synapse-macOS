import SwiftUI

/// Design tokens. One accent, neutral surfaces, system typography.
enum Theme {
    static let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
    // Logo colors only; the rest of the app stays neutral.
    static let markPink = Color(red: 1.0, green: 0.36, blue: 0.74)
    static let markViolet = Color(red: 0.49, green: 0.36, blue: 1.0)
    static let markCyan = Color(red: 0.16, green: 0.80, blue: 1.0)

    static let background = Color(red: 0.04, green: 0.042, blue: 0.046)    // near-black graphite
    static let fill = Color.white.opacity(0.05)          // subtle backgrounds (chips, rows)
    static let fillStrong = Color.white.opacity(0.09)    // hovered rows
    static let border = Color.white.opacity(0.09)
    static let composer = Color.white.opacity(0.04)

    static let radius: CGFloat = 10
}

/// The Synapse mark: a signal arc joining two glowing nodes.
struct SynapseLogo: View {
    var size: CGFloat = 20
    var tile = false

    var body: some View {
        Canvas { ctx, s in
            let w = s.width
            if tile {
                let rect = CGRect(origin: .zero, size: s)
                ctx.fill(Path(roundedRect: rect, cornerRadius: w * 0.23, style: .continuous),
                         with: .linearGradient(Gradient(colors: [Color(red: 0.13, green: 0.09, blue: 0.30), Color(red: 0.03, green: 0.03, blue: 0.10)]),
                                               startPoint: .zero, endPoint: CGPoint(x: w, y: w)))
            }
            let inset = tile ? 0.0 : -0.06   // fill more of the frame when there's no tile
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: w * (inset + x * (1 - 2 * inset)), y: w * (inset + y * (1 - 2 * inset)))
            }
            let a = p(0.27, 0.70), b = p(0.73, 0.30)
            var arc = Path()
            arc.move(to: a)
            arc.addCurve(to: b, control1: p(0.27, 0.26), control2: p(0.73, 0.74))
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Theme.markPink, Theme.markViolet, Theme.markCyan]), startPoint: a, endPoint: b)
            var glow = ctx
            glow.addFilter(.blur(radius: w * 0.05))
            glow.stroke(arc, with: shading, style: StrokeStyle(lineWidth: w * 0.12, lineCap: .round))
            ctx.stroke(arc, with: shading, style: StrokeStyle(lineWidth: w * 0.08, lineCap: .round))
            for (c, col, r) in [(a, Theme.markPink, 0.11), (b, Theme.markCyan, 0.11), (p(0.5, 0.5), Color.white, 0.06)] {
                let rr = w * r
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(col))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - rr * 0.45, y: c.y - rr * 0.45, width: rr * 0.9, height: rr * 0.9)),
                         with: .color(.white.opacity(0.85)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Synapse")
    }
}

#Preview { SynapseLogo(size: 128, tile: true).padding() }
