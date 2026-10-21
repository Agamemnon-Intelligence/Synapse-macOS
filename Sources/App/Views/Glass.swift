import SwiftUI

extension View {
    /// Liquid Glass on macOS 26+, frosted material before that.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(tint.map { AnyShapeStyle($0.opacity(0.25)) } ?? AnyShapeStyle(.clear), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.border))
        }
    }

    @available(macOS 26.0, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups nearby glass shapes so they blend together (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Deep backdrop with soft color, so the glass has something to refract.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Circle().fill(Theme.markBlue.opacity(0.16))
                    .frame(width: w * 0.7, height: w * 0.7)
                    .blur(radius: 120)
                    .position(x: w * 0.15, y: h * 0.05)
                Circle().fill(Theme.markViolet.opacity(0.13))
                    .frame(width: w * 0.6, height: w * 0.6)
                    .blur(radius: 130)
                    .position(x: w * 0.95, y: h * 0.95)
                Circle().fill(Theme.markCoral.opacity(0.05))
                    .frame(width: w * 0.35, height: w * 0.35)
                    .blur(radius: 110)
                    .position(x: w * 0.75, y: h * 0.2)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
