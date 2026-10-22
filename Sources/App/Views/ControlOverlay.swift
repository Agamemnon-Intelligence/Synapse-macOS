import SwiftUI
import AppKit

/// While the model is acting on the Mac (shell, AppleScript, apps, browser), a soft sea-wave
/// glow runs around every screen's edge, with a pill at the top saying so and a Stop button.
@MainActor
final class ControlOverlay {
    var onStop: ((UUID) -> Void)?
    private var glowWindows: [NSWindow] = []
    private var pill: NSPanel?
    private var activeChat: UUID?

    func show(chatID: UUID) {
        activeChat = chatID
        guard glowWindows.isEmpty else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            configure(w)
            w.ignoresMouseEvents = true
            w.contentView = NSHostingView(rootView: SeaGlow())
            w.setFrame(screen.frame, display: false)
            w.alphaValue = 0
            w.orderFrontRegardless()
            glowWindows.append(w)
        }
        if let screen = NSScreen.main {
            let size = NSSize(width: 420, height: 64)
            let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12)
            let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            configure(p)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.becomesKeyOnlyIfNeeded = true
            p.contentView = NSHostingView(rootView: ControlPill { [weak self] in
                guard let self, let id = self.activeChat else { return }
                self.onStop?(id)
            })
            p.alphaValue = 0
            p.orderFrontRegardless()
            pill = p
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            (glowWindows + [pill].compactMap { $0 }).forEach { $0.animator().alphaValue = 1 }
        }
    }

    func hide(chatID: UUID) {
        guard activeChat == chatID || chatID == UUID(uuid: UUID_NULL) else { return }
        let windows = glowWindows + [pill].compactMap { $0 }
        glowWindows = []
        pill = nil
        activeChat = nil
        guard !windows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            windows.forEach { $0.orderOut(nil) }
        })
    }

    private func configure(_ w: NSWindow) {
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// A slow, rolling teal-to-blue light that hugs the screen edge like a wave.
private struct SeaGlow: View {
    static let colors: [Color] = [
        Color(red: 0.18, green: 0.86, blue: 0.78), Color(red: 0.20, green: 0.74, blue: 0.98),
        Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.62, green: 0.93, blue: 1.0),
        Color(red: 0.18, green: 0.86, blue: 0.78),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(t.truncatingRemainder(dividingBy: 9) / 9 * 360)
            let breathe = 0.75 + 0.25 * sin(t * 1.6)
            let gradient = AngularGradient(colors: Self.colors, center: .center, angle: angle)
            ZStack {
                // Wide, soft wash that rolls along the edge.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 46)
                    .blur(radius: 38)
                    .opacity(0.42 * breathe)
                // Mid glow.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 10)
                    .blur(radius: 9)
                    .opacity(0.8 * breathe)
                // Crisp rim.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 2.5)
                    .opacity(0.9)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct ControlPill: View {
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.animation) { t in
                let p = (sin(t.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
                Circle()
                    .fill(SeaGlow.colors[0])
                    .frame(width: 9, height: 9)
                    .shadow(color: SeaGlow.colors[1].opacity(0.9), radius: 4 + 4 * p)
                    .opacity(0.55 + 0.45 * p)
            }
            .frame(width: 12)
            Text("Synapse is controlling your device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Button(action: onStop) {
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .glass(Capsule(), tint: Color(red: 0.05, green: 0.25, blue: 0.35).opacity(0.5))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}
