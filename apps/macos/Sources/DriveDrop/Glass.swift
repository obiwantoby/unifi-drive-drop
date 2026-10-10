import SwiftUI
import AppKit

// MARK: - Glass primitives (macOS 26 liquid glass, material fallback below)

struct GlassCard<Content: View>: View {
    var corner: CGFloat = 16
    var tint: Color? = nil
    @ViewBuilder var content: Content

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = .regular.interactive()
        if let tint { g = g.tint(tint) }
        return g
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            content
                .padding(12)
                .glassEffect(glass, in: .rect(cornerRadius: corner))
        } else {
            content
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
        }
    }
}

/// Window backdrop.
struct Backdrop: View {
    var body: some View {
        VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
            .ignoresSafeArea()
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

// MARK: - Glass modifiers

extension View {
    /// A glass surface behind the content: real liquid glass on macOS 26, ultra-thin material
    /// below. Written once so the popover and the window cannot drift apart.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 14, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let g: Glass = interactive ? .regular.interactive() : .regular
            self.glassEffect(g, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
        }
    }

    /// The capsule form, for floating confirmations.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
    }

    /// `.glass` / `.glassProminent` where the OS has them, bordered equivalents below.
    /// The two styles are distinct types, so the choice is branches rather than a ternary.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) }
            else { self.buttonStyle(.glass) }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
