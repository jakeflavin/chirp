import SwiftUI

// Liquid Glass (macOS 26), in one place. Glass is for controls and navigation only: the perch, the menu
// bar popover, the sidebar, toolbar groups, the start bar and a recording's bottom bar. Content stays on
// paper. Never glass on glass: what sits on a glass surface uses a fill (`GlassFill`), and only the
// action in use is tinted. See Docs/DESIGN.md (section 6, Liquid Glass).

/// The words, icons and fills that go on a glass surface (the perch, the menu bar popover, glass controls):
/// the system's own ink, at low strength for fills, so they follow the glass when it turns dark over dark
/// content. `GlassFill.hover` is the usual set; `GlassFill(strong: true)` is the set for Increase Contrast.
struct GlassFill {
    /// Everything stronger, for Increase Contrast.
    var strong = false

    /// Words and icons.
    var ink: Color { Color.primary }
    /// Supporting words. A little stronger than the system's second level, which washes out on glass.
    var quiet: Color { Color.primary.opacity(strong ? 0.86 : 0.62) }
    /// Words that matter least, such as a time beside a title.
    var faint: Color { Color.primary.opacity(strong ? 0.8 : 0.52) }
    /// Under the pointer, and a quiet chip.
    var hover: Color { Color.primary.opacity(strong ? 0.22 : 0.08) }
    /// A chosen row, and a control's fill at rest.
    var row: Color { Color.primary.opacity(strong ? 0.14 : 0.07) }
    /// A hairline between parts of one surface.
    var line: Color { Color.primary.opacity(strong ? 0.4 : 0.12) }
    /// A track, a handle.
    var track: Color { Color.primary.opacity(strong ? 0.4 : 0.18) }

    /// The usual set, for surfaces that do not change with Increase Contrast.
    static let standard = GlassFill()
    static var ink: Color { standard.ink }
    static var quiet: Color { standard.quiet }
    static var faint: Color { standard.faint }
    static var hover: Color { standard.hover }
    static var row: Color { standard.row }
    static var line: Color { standard.line }
    static var track: Color { standard.track }
}

/// One Liquid Glass surface behind a view, in the shape given. It follows the user's accessibility
/// settings: with Reduce Transparency it is a solid surface in Chirp's Float colour, and with Increase
/// Contrast it gets a firm edge.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    /// Tints the glass. Only for the one action in use; leave nil for a plain surface.
    var tint: Color?
    /// The glass answers the pointer, as a glass button does.
    var interactive = false
    /// False draws nothing at all, for a state that has no surface (the perch as a bare wire).
    var shown = true
    /// How much of Chirp's Float colour is laid over the glass, 0…1. Glass alone takes its lightness from
    /// what is behind it; a surface that holds words to read (the perch) needs a steady ground under
    /// them in light and in dark. Leave at 0 for a control that holds only an icon or a word.
    var wash: Double = 0

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if !shown {
            content
        } else if reduceTransparency {
            content
                .background(shape.fill(Color.float).shadow(color: .black.opacity(0.22), radius: 12, y: 5))
                .overlay(shape.strokeBorder(Color.ink.opacity(contrast == .increased ? 0.55 : 0.16), lineWidth: 1))
        } else {
            content
                .background(shape.fill(Color.float.opacity(wash)))
                .glassEffect(glass, in: shape)
                .overlay(shape.strokeBorder(Color.ink.opacity(contrast == .increased ? 0.55 : 0), lineWidth: 1))
        }
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Puts one Liquid Glass surface behind the view. Use it for controls and navigation, never for
    /// content and never on top of another glass surface.
    func chirpGlass(in shape: some InsettableShape, tint: Color? = nil, interactive: Bool = false, shown: Bool = true, wash: Double = 0) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, shown: shown, wash: wash))
    }

    /// Glass in a capsule: a toolbar group, a search field, a start bar.
    func chirpGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        chirpGlass(in: Capsule(), tint: tint, interactive: interactive)
    }
}

/// How a glass surface changes shape. Growing has a little spring; shrinking settles without one.
/// With Reduce Motion both are a short fade.
enum GlassMotion {
    static let grow = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let shrink = Animation.spring(response: 0.45, dampingFraction: 1.0)
    /// What is inside the shape cross-fades over this long.
    static let content = Animation.easeInOut(duration: 0.35)
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func shape(growing: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : growing ? grow : shrink
    }
}
