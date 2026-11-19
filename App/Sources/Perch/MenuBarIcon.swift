import AppKit
import SwiftUI

/// Chirp's bird as a one-colour menu bar shape: round body, short beak, stubby tail, the eye as a gap.
enum MenuBarIcon {
    /// The bird alone, drawn once: the label is redrawn every second while a recording's clock runs.
    @MainActor static let template = image()

    /// `tint` nil gives a template image that follows the menu bar's own colour.
    static func image(tint: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let t = AffineTransform(scaleByX: size.width / 44, byY: size.height / 40)
            (tint ?? .black).setFill()
            // Each part is filled on its own, so overlapping parts never cancel each other out.
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 12, y: 21))
            tail.curve(to: NSPoint(x: 1, y: 17), controlPoint1: NSPoint(x: 6, y: 22), controlPoint2: NSPoint(x: 2.3, y: 20.3))
            tail.curve(to: NSPoint(x: 13, y: 28), controlPoint1: NSPoint(x: 2.3, y: 23.7), controlPoint2: NSPoint(x: 6, y: 27.5))
            tail.close()
            let body = NSBezierPath(ovalIn: NSRect(x: 8, y: 6, width: 28, height: 28))
            let beak = NSBezierPath()
            beak.move(to: NSPoint(x: 35, y: 16.5))
            beak.curve(to: NSPoint(x: 41.5, y: 19), controlPoint1: NSPoint(x: 39.2, y: 16.8), controlPoint2: NSPoint(x: 41.2, y: 17.7))
            beak.curve(to: NSPoint(x: 35, y: 21.5), controlPoint1: NSPoint(x: 40.8, y: 20.3), controlPoint2: NSPoint(x: 38.8, y: 21.2))
            beak.close()
            for part in [tail, body, beak] {
                part.transform(using: t)
                part.fill()
            }
            // The eye is cut out, so it shows the menu bar through it.
            let eye = NSBezierPath(ovalIn: NSRect(x: 25.4, y: 12.4, width: 5.2, height: 5.2))
            eye.transform(using: t)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            eye.fill()
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}

extension MenuBarIcon {
    /// The bird at part strength, for "working". Still a template, so the menu bar picks its colour.
    @MainActor static let dimmed = faded(0.5)
    /// The bird with a small microphone after it: dictating.
    @MainActor static let dictating = withSymbol("chirp.dictate")
    /// The bird with a small speaker after it: reading aloud.
    @MainActor static let reading = withSymbol("chirp.read")
    /// The bird with "!" after it: something needs a look.
    @MainActor static let attention = withMark("!")
    /// The recording light. Red is the only colour the menu bar item ever shows, and only while recording.
    @MainActor static let recordingDot: NSImage = {
        let image = NSImage(size: NSSize(width: 7, height: 7), flipped: true) { rect in
            // One red for a light and a dark menu bar: the dark value of Robin is too pale to read as a recording light.
            NSColor(Color.recordLight).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    /// The bird drawn at `alpha`, as a template.
    static func faded(_ alpha: CGFloat) -> NSImage {
        let bird = image()
        let out = NSImage(size: bird.size, flipped: false) { rect in
            bird.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        out.isTemplate = true
        return out
    }

    /// The bird with a small Chirp icon (asset catalog symbol) to its right, as one template image.
    static func withSymbol(_ name: String) -> NSImage {
        let bird = image()
        let symbol = NSImage(named: name)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        let symbolSize = symbol?.size ?? .zero
        let size = NSSize(width: bird.size.width + 3 + symbolSize.width, height: bird.size.height)
        let out = NSImage(size: size, flipped: false) { _ in
            bird.draw(in: NSRect(origin: .zero, size: bird.size))
            symbol?.draw(in: NSRect(x: bird.size.width + 3, y: (size.height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
            return true
        }
        out.isTemplate = true
        return out
    }

    /// The bird with a short bold mark to its right, as one template image.
    static func withMark(_ mark: String) -> NSImage {
        let bird = image()
        let text = NSAttributedString(string: mark, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .heavy), .foregroundColor: NSColor.black])
        let textSize = text.size()
        let size = NSSize(width: bird.size.width + 3 + ceil(textSize.width), height: bird.size.height)
        let out = NSImage(size: size, flipped: false) { _ in
            bird.draw(in: NSRect(origin: .zero, size: bird.size))
            text.draw(at: NSPoint(x: bird.size.width + 3, y: (size.height - textSize.height) / 2))
            return true
        }
        out.isTemplate = true
        return out
    }
}

/// What the menu bar item shows Chirp doing.
enum MenuIconState: Equatable {
    case idle
    case dictating
    /// With the time so far, as "12:04".
    case recording(String)
    case reading
    case working
    /// Something is waiting to be looked at: finished notes, or a problem.
    case attention

    /// What VoiceOver says for the menu bar item.
    var spoken: String {
        switch self {
        case .idle: "Chirp"
        case .dictating: "Chirp, dictating"
        case .recording(let time): "Chirp, recording, \(time)"
        case .reading: "Chirp, reading aloud"
        case .working: "Chirp, working"
        case .attention: "Chirp, needs a look"
        }
    }
}

extension MenuBarIcon {
    /// Draws one state on the menu bar item: the bird alone at rest; with a microphone while dictating;
    /// with a red dot and the time while recording; with a speaker while reading aloud; going faint and
    /// back while working; with "!" when something needs a look. Black and clear, so the system
    /// recolours it; red only while recording.
    /// - Parameters:
    ///   - dim: while working, true shows the bird faint and false at full strength; swapping the two is the pulse.
    ///   - showTimer: false leaves the time out beside the red dot (the dot stays).
    @MainActor static func show(_ state: MenuIconState, dim: Bool, showTimer: Bool, on button: NSStatusBarButton) {
        var title = NSAttributedString()
        switch state {
        case .idle: button.image = template
        case .dictating: button.image = dictating
        case .reading: button.image = reading
        case .working: button.image = dim ? dimmed : template
        case .attention: button.image = attention
        case .recording(let time):
            button.image = template
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            let dot = NSTextAttachment()
            dot.image = recordingDot
            // Centred on the digits: half the height of a capital, less half the dot.
            dot.bounds = NSRect(x: 0, y: (font.capHeight - recordingDot.size.height) / 2, width: recordingDot.size.width, height: recordingDot.size.height)
            let text = NSMutableAttributedString(string: " ")
            text.append(NSAttributedString(attachment: dot))
            if showTimer { text.append(NSAttributedString(string: " " + time)) }
            // The text colour is the control's own, which follows the menu bar; only the dot is red.
            text.addAttributes([.font: font, .foregroundColor: NSColor.controlTextColor], range: NSRange(location: 0, length: text.length))
            title = text
        }
        button.attributedTitle = title
        button.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(state.spoken)
    }
}
