import ChirpCore
import SwiftUI

/// Shows the Markdown a language model wrote (a summary, notes) as a small article: headings, paragraphs,
/// lists and blocks of code, instead of its raw marks. `size` is the body text's point size; headings and
/// spacing are set from it.
struct MarkdownText: View {
    let lines: [MarkdownLines.Line]
    var size: CGFloat = 13

    init(_ markdown: String, size: CGFloat = 13) {
        lines = MarkdownLines.parse(markdown)
        self.size = size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Group {
                    switch line.kind {
                    case .heading(let level):
                        Text(Self.inline(line.text))
                            .font(.system(size: size + (level <= 1 ? 4 : level == 2 ? 2.5 : 1), weight: level <= 2 ? .bold : .semibold))
                            .accessibilityAddTraits(.isHeader)
                    case .point(let marker, let depth):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marker).foregroundStyle(Color.quiet).monospacedDigit()
                            Text(Self.inline(line.text)).lineSpacing(size * 0.22)
                        }
                        .font(.system(size: size))
                        .padding(.leading, CGFloat(min(depth, 3)) * 14 + 2)
                    case .text:
                        Text(Self.inline(line.text)).font(.system(size: size)).lineSpacing(size * 0.28)
                    case .code:
                        // Long lines scroll sideways: wrapped code is hard to read and easy to copy wrong.
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(line.text)
                                .font(.system(size: size - 1.5, design: .monospaced))
                                .lineSpacing(2)
                                .fixedSize()
                                .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel("Code: \(line.text)")
                    }
                }
                .padding(.top, gap(before: index))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The space above a line: most above a heading, a paragraph's worth between paragraphs, little
    /// between the points of one list or under a heading.
    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let line = lines[index].kind, above = lines[index - 1].kind
        if case .heading = line { return size * 1.25 }
        if case .heading = above { return size * 0.4 }
        if case .point = line, case .point = above { return size * 0.36 }
        return size * 0.75
    }

    /// Bold, italics, code and links inside one line; the plain words if the marks do not parse.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
