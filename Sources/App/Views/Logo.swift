import SwiftUI

/// Design tokens. One accent, neutral surfaces, system typography.
enum Theme {
    static let accent = Color(red: 0.24, green: 0.48, blue: 1.0)
    static let markBlue = Color(red: 0.24, green: 0.55, blue: 1.0)
    static let markViolet = Color(red: 0.63, green: 0.36, blue: 0.96)
    static let markCoral = Color(red: 1.0, green: 0.42, blue: 0.36)

    static let background = Color(red: 0.035, green: 0.039, blue: 0.055)   // near-black, slightly cool
    static let fill = Color.white.opacity(0.05)          // subtle backgrounds (chips, rows)
    static let fillStrong = Color.white.opacity(0.09)    // hovered rows
    static let border = Color.white.opacity(0.09)
    static let composer = Color.white.opacity(0.04)

    static let radius: CGFloat = 10
}

/// The Synapse mark: an S-shaped signal path with a spark at its center.
struct SynapseLogo: View {
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, s in
            let w = s.width
            let line = w * 0.17
            func arc(_ cy: CGFloat, _ start: Double, _ end: Double, clockwise: Bool) -> Path {
                var p = Path()
                p.addArc(center: CGPoint(x: w * 0.5, y: w * cy), radius: w * 0.2,
                         startAngle: .radians(.pi * start), endAngle: .radians(.pi * end), clockwise: clockwise)
                return p
            }
            let style = StrokeStyle(lineWidth: line, lineCap: .round)
            ctx.stroke(arc(0.305, -0.08, 0.62, clockwise: true), with: .color(Theme.markBlue), style: style)
            ctx.stroke(arc(0.695, -0.38, 0.92, clockwise: false), with: .color(Theme.markViolet), style: style)
            let r = w * 0.075
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.5 - r, y: w * 0.5 - r, width: r * 2, height: r * 2)), with: .color(Theme.markCoral))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Synapse")
    }
}

#Preview { SynapseLogo(size: 128).padding() }
