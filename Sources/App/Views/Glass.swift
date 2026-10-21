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

/// Dark graphite backdrop with a faint cool glow, so the glass has something to refract.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Circle().fill(Theme.accent.opacity(0.07))
                    .frame(width: w * 0.7, height: w * 0.7)
                    .blur(radius: 140)
                    .position(x: w * 0.1, y: h * 0.0)
                Circle().fill(Color.white.opacity(0.025))
                    .frame(width: w * 0.55, height: w * 0.55)
                    .blur(radius: 140)
                    .position(x: w * 0.95, y: h * 1.0)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
