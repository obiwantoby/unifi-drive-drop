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
