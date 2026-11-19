import AppKit
import ChirpCore
import SwiftUI

// The underlines in Chirp's own editors (the Write panel, notes) and onboarding's example, drawn with the
// same lines as over other apps (`UnderlineLook`): spelling wavy, grammar solid, style dashed, a
// snippet's cue dotted, a likely name thinner and fainter. AppKit has no wavy underline, so the editors'
// layout manager draws each one itself where the text system would draw its own.

extension NSAttributedString.Key {
    /// A temporary attribute on a problem's range: its `UnderlinePattern` raw value, with the width and
    /// strength in `chirpUnderlineLook`.
    static let chirpUnderline = NSAttributedString.Key("chirpUnderline")
}

/// Marks a text view's problems for `PatternLayoutManager` to underline. Clears the old marks first.
@MainActor
enum IssueMarks {
    static func mark(_ issues: [WritingIssue], in layout: NSLayoutManager, text: String, names: Bool = true) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        layout.removeTemporaryAttribute(.chirpUnderline, forCharacterRange: full)
        for issue in issues where NSMaxRange(issue.range) <= full.length {
            let name = names && Proofreading.likelyName(issue, in: text)
            layout.addTemporaryAttributes(
                [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: issue.category.color,
                 .chirpUnderline: PatternLayoutManager.code(issue.category, likelyName: name)],
                forCharacterRange: issue.range)
        }
    }
}

/// A layout manager that draws a problem's underline in its own pattern (`UnderlineLook`).
class PatternLayoutManager: NSLayoutManager {
    /// What a range carries: the category and whether it is a likely name, as "spelling" or "spelling.name".
    static func code(_ category: IssueCategory, likelyName: Bool) -> String {
        category.rawValue + (likelyName ? ".name" : "")
    }

    override func drawUnderline(
        forGlyphRange glyphRange: NSRange, underlineType: NSUnderlineStyle, baselineOffset: CGFloat,
        lineFragmentRect lineRect: NSRect, lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: NSPoint
    ) {
        let char = characterIndexForGlyph(at: glyphRange.location)
        let attributes = temporaryAttributes(atCharacterIndex: char, effectiveRange: nil)
        guard let code = attributes[.chirpUnderline] as? String,
            let category = IssueCategory(rawValue: String(code.split(separator: ".").first ?? "")),
            let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil),
            let context = NSGraphicsContext.current?.cgContext
        else {
            return super.drawUnderline(
                forGlyphRange: glyphRange, underlineType: underlineType, baselineOffset: baselineOffset,
                lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
        }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let look = UnderlineLook.of(category, likelyName: code.hasSuffix(".name"), dark: dark)
        // Trailing spaces are not underlined.
        var glyphs = glyphRange
        let text = (textStorage?.string ?? "") as NSString
        while glyphs.length > 0 {
            let c = characterIndexForGlyph(at: NSMaxRange(glyphs) - 1)
            guard c < text.length, [32, 9, 10, 13].contains(text.character(at: c)) else { break }
            glyphs.length -= 1
        }
        guard glyphs.length > 0 else { return }
        let box = boundingRect(forGlyphRange: glyphs, in: container)
        // Under the baseline, by as much as the line needs, so a wave's crest never reaches the letters.
        let baseline = lineRect.minY + location(forGlyphAt: glyphs.location).y + containerOrigin.y
        let y = baseline + 1.5 + look.reach
        let inset = min(1, box.width / 4)
        let path = look.path(from: box.minX + containerOrigin.x + inset, to: box.maxX + containerOrigin.x - inset, y: y)
        let colour = (attributes[.underlineColor] as? NSColor) ?? category.color
        context.saveGState()
        context.setStrokeColor(colour.withAlphaComponent(look.opacity).cgColor)
        context.setLineWidth(look.width)
        context.setLineCap(look.dash == nil ? .butt : .round)
        if let dash = look.dash { context.setLineDash(phase: 0, lengths: dash) }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

/// A sentence with problems underlined as Chirp underlines them, for onboarding's example.
struct UnderlineSample: NSViewRepresentable {
    let text: String
    /// Each underlined part: the words and their kind.
    let marks: [(words: String, category: IssueCategory)]
    var size: CGFloat = 15

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextStorage()
        let layout = PatternLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        update(view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) { update(view) }

    private func update(_ view: NSTextView) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(named: "Ink") ?? .labelColor, .paragraphStyle: style,
        ]))
        guard let layout = view.layoutManager else { return }
        let ns = text as NSString
        let issues = marks.compactMap { mark -> WritingIssue? in
            let range = ns.range(of: mark.words)
            guard range.location != NSNotFound else { return nil }
            let kind = switch mark.category {
            case .spelling: "Spelling"
            case .grammar: "Grammar"
            case .style: "Style"
            case .snippet: "Snippet"
            }
            return WritingIssue(start: range.location, end: NSMaxRange(range), rule: "Sample", kind: kind, message: "")
        }
        IssueMarks.mark(issues, in: layout, text: text, names: false)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let layout = nsView.layoutManager, let container = nsView.textContainer else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // Room under the last line for its underline.
        return CGSize(width: width, height: ceil(used.height) + 6)
    }
}
