import AppKit
import SwiftUI

/// A small always-on-top panel that never takes keyboard focus.
@MainActor
final class FloatingPanel {
    /// Where on the screen the panel sits.
    enum Corner { case topRight, bottomCenter }
    private var panel: NSPanel?

    /// Shows `view` in the panel at one of the fixed places on the main screen.
    func show<V: View>(_ view: V, size: NSSize, corner: Corner) {
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            return p
        }()
        panel = p
        p.contentView = NSHostingView(rootView: view)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin: NSPoint
        switch corner {
        case .topRight: origin = NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12)
        case .bottomCenter: origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 28)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
    }

    /// Shows the panel with its bottom-left corner at `point`, kept on screen.
    func show<V: View>(_ view: V, size: NSSize, at point: NSPoint) {
        show(view, size: size, corner: .topRight)
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(point.x, screen.minX + 4), screen.maxX - size.width - 4)
        // Below the text if there is room, otherwise above it.
        let y = point.y >= screen.minY + 4 ? point.y : point.y + size.height + 30
        panel?.setFrameOrigin(NSPoint(x: x, y: min(y, screen.maxY - size.height - 4)))
    }

    func hide() { panel?.orderOut(nil) }
    var isVisible: Bool { panel?.isVisible ?? false }
    /// Where the panel is on screen, while it is showing.
    var frame: NSRect? { isVisible ? panel?.frame : nil }
}
