import SwiftUI

/// Whether this build is the Beta. One build flag decides it: `CHIRP_CHANNEL: Beta` in `project.yml`
/// sets the `BETA` compilation condition and picks the Beta app icon. Take that line's value away and
/// none of what is here shows: no tag, no mark on the perch, and the version only in Settings › General.
enum Beta {
    static var isOn: Bool {
        #if BETA
        return true
        #else
        return false
        #endif
    }

    /// "0.1.0"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    /// "2"
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    /// The version and build as shown: "0.1.0 (2)".
    static var versionLine: String { build.isEmpty ? version : "\(version) (\(build))" }
}

/// The one "Beta" tag: a small quiet capsule, the same wherever it appears. In a window it uses Chirp's
/// ink; on glass (the perch, the menu bar popover) it uses the system's ink, which follows light and
/// dark with the glass (Docs/DESIGN.md, section 4, Colour, rule 6).
struct BetaTag: View {
    var onGlass = false

    var body: some View {
        Text("Beta")
            .font(.system(size: 10, weight: .semibold)).tracking(0.2)
            .foregroundStyle(onGlass ? Color.primary.opacity(0.7) : Color.quiet)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).frame(height: 15)
            .background(onGlass ? Color.primary.opacity(0.1) : Color.ink.opacity(0.09), in: Capsule())
            .accessibilityLabel("Beta version")
    }
}

/// The top of the sidebar in a Beta build: Chirp's name with the tag beside it, and the version and
/// build under it.
struct BetaSidebarHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Chirp").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                BetaTag()
            }
            Text(Beta.versionLine).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.quiet)
        }
        .padding(.leading, 8).padding(.bottom, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chirp Beta, version \(Beta.versionLine)")
        .accessibilityIdentifier("sidebar.beta")
    }
}
