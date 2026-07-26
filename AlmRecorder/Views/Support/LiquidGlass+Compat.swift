import SwiftUI
import AppKit

// MARK: - Liquid Glass compatibility shim
//
// Centralizes every `if #available(macOS 26, *)` branch for the Liquid Glass
// migration so call sites stay clean. Signatures validated against the
// Xcode 26.5 SwiftUI/SwiftUICore SDK interfaces.
//
// Rules of the road:
//   • Liquid Glass is for the NAVIGATION / CHROME layer only (floating panels,
//     custom controls). Standard chrome (toolbars, SidebarListStyle, sheets,
//     popovers, TabView) adopts glass automatically when built against the
//     macOS 26 SDK — do NOT wrap those.
//   • CONTENT (cards, panes, lists, text) is never glass. Use `cardSurface` /
//     `contentSurface`, which are opaque and identical on every OS version.

// Semantic card corner-radius scale — use these instead of ad-hoc literals.
enum CardRadius {
    static let chip: CGFloat = 6        // pills, tags, badges, search fields
    static let card: CGFloat = 12       // default content cards (cardSurface default)
    static let prominent: CGFloat = 16  // hero / standalone status cards
}

// MARK: Content surfaces (UNGATED — opaque on every OS; content is never glass)

extension View {
    /// Opaque, adaptive surface for CONTENT cards. Solid on every macOS version
    /// (never glass). Matches the app's existing `Color(NSColor.controlBackgroundColor)`
    /// house style. Clips its own rounded-rect shape, so callers should drop any
    /// separate `.cornerRadius(_:)`.
    func cardSurface(cornerRadius: CGFloat = 12,
                     strokeColor: Color? = nil,
                     strokeWidth: CGFloat = 1) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                if let strokeColor {
                    shape.strokeBorder(strokeColor, lineWidth: strokeWidth)
                }
            }
    }

    /// A prominent content card (larger radius for hero / standalone cards).
    func cardSurfaceProminent(strokeColor: Color? = nil, strokeWidth: CGFloat = 1) -> some View {
        cardSurface(cornerRadius: CardRadius.prominent, strokeColor: strokeColor, strokeWidth: strokeWidth)
    }

    /// Opaque content surface in an arbitrary shape (chips / pills / circles).
    func contentSurface(in shape: some Shape) -> some View {
        self.background(Color(nsColor: .controlBackgroundColor), in: shape)
    }
}

// MARK: Genuine floating chrome (GATED — Liquid Glass on 26, material fallback)

extension View {
    /// Liquid Glass for a hand-rolled floating panel/banner that does NOT auto-adopt
    /// (i.e. NOT a standard toolbar / sidebar / sheet). Falls back to a material on
    /// older systems. Reserve for things that genuinely float above content.
    @ViewBuilder
    func glassPanel(in shape: some Shape = RoundedRectangle(cornerRadius: 12, style: .continuous),
                    tint: Color? = nil,
                    interactive: Bool = false,
                    fallback: Material = .regularMaterial) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }
}

@available(macOS 26, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

// MARK: Glass buttons (GATED — native glass on 26, bordered fallback)

/// Border shape for ``View/glassButton(tint:prominent:)``.
enum GlassButtonShape { case capsule, circle, roundedRect }

extension View {
    /// `.glass` / `.glassProminent` on macOS 26; `.bordered` / `.borderedProminent`
    /// on older systems. `prominent` marks the single tinted call-to-action of a group.
    @ViewBuilder
    func glassButton(tint: Color? = nil, prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent).tint(tint)
            } else {
                self.buttonStyle(.bordered).tint(tint)
            }
        }
    }

    /// Border shape for a glass button (macOS 26 only; no-op below). The `.circle`
    /// case also applies an explicit `clipShape(Circle())` to work around the
    /// `.glassProminent` + circle rendering glitch.
    @ViewBuilder
    func glassButtonShape(_ shape: GlassButtonShape) -> some View {
        if #available(macOS 26, *) {
            switch shape {
            case .capsule:
                self.buttonBorderShape(.capsule)
            case .roundedRect:
                self.buttonBorderShape(.roundedRectangle)
            case .circle:
                self.buttonBorderShape(.circle).clipShape(Circle())
            }
        } else {
            self
        }
    }

    /// Concentric corners aligned to the enclosing glass container on macOS 26
    /// (via `ConcentricRectangle`); a fixed continuous radius on older systems.
    @ViewBuilder
    func concentricCornerClip(fallback radius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            self.clipShape(ConcentricRectangle())
        } else {
            self.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    /// Hides a Form/scroll background on macOS 26 so chrome glass shows through;
    /// leaves the default background on older systems.
    @ViewBuilder
    func glassFormBackground() -> some View {
        if #available(macOS 26, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

// MARK: Sidebar translucency (clear the column's frosted backing)

extension View {
    /// Makes a `NavigationSplitView` sidebar read as translucent Liquid Glass.
    ///
    /// The split view paints its sidebar column with the frosted `.sidebar`
    /// `NSVisualEffectView` material, which sits UNDER the sidebar content and soaks up the
    /// translucency — so the sidebar looks frosted/charcoal even though a `.listStyle(.sidebar)`
    /// list floating over a CLEAR content pane looks genuinely see-through. SwiftUI exposes no
    /// API to change that column material, so we reach the enclosing effect view and swap it for
    /// the most see-through standard material, matching the clear content panes.
    /// `.scrollContentBackground(.hidden)` only hides the List's own backing — not this one.
    func clearSidebarBacking(_ material: NSVisualEffectView.Material = .underWindowBackground) -> some View {
        background(SidebarBackingClearer(material: material))
    }
}

private struct SidebarBackingClearer: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSView { ProbeView(material: material) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.applyToEnclosingEffectView()
    }

    /// A zero-size probe placed in the sidebar's background layer. From there it walks up to the
    /// enclosing `NSVisualEffectView` (the column backing) and retints it. Re-applied on
    /// `viewDidMoveToWindow` and on every SwiftUI update (e.g. selection changes) so the system
    /// can't quietly reset it.
    final class ProbeView: NSView {
        let material: NSVisualEffectView.Material
        init(material: NSVisualEffectView.Material) {
            self.material = material
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToEnclosingEffectView()
        }

        func applyToEnclosingEffectView() {
            var ancestor = superview
            while let view = ancestor {
                // Retint EVERY enclosing effect view, not just the first. The user's "stacking"
                // hunch was literal: the sidebar column backing AND the window backing each add a
                // frosted layer and they compound, so clearing only the innermost barely moved it.
                if let effect = view as? NSVisualEffectView {
                    effect.material = material
                    effect.blendingMode = .behindWindow
                    effect.state = .active
                }
                ancestor = view.superview
            }
        }
    }
}

// Phase 3 (append when needed): glassScrollEdge() [scrollEdgeEffectStyle],
// glassBackgroundExtension() [backgroundExtensionEffect], and a
// GlassEffectContainer + glassEffectID wrapper for the record-button morph.
