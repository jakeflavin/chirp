import AppKit
import ChirpCore
import PDFKit
import Quartz
import SwiftUI
import WebKit

/// The original of a document, as it was: a PDF's pages, a Word file's pages, or the copy of a web
/// page that was saved with it. Shown on a grey ground, apart from the paper the reading view is on.
struct OriginalView: View {
    let url: URL
    /// The page's address, for a saved copy of a web page.
    let source: String?
    @State private var page = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch url.pathExtension.lowercased() {
            // The pages sit as sheets on the grey ground, no wider than a page reads well.
            case "pdf": PDFPages(url: url, page: $page).frame(maxWidth: 640).frame(maxWidth: .infinity)
            case "webarchive", "html", "htm", "xhtml": SavedPage(url: url, base: source.flatMap(URL.init(string:)))
            default: QuickLookPages(url: url)
            }
            if !page.isEmpty {
                Text(page).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.ink)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Color.card.opacity(0.9), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.ink.opacity(0.12), lineWidth: 0.5))
                    .padding(.top, 14).padding(.trailing, 16)
                    .accessibilityIdentifier("original.page")
            }
        }
        .background(Color.ink.opacity(0.08))
        .accessibilityIdentifier("document.original")
    }
}

/// A PDF's pages, one under another, with the page in view counted.
private struct PDFPages: NSViewRepresentable {
    let url: URL
    @Binding var page: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.backgroundColor = .clear
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
        context.coordinator.say(view)
    }

    final class Coordinator: NSObject {
        var parent: PDFPages
        init(_ parent: PDFPages) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) { if let view = note.object as? PDFView { say(view) } }

        func say(_ view: PDFView) {
            guard let document = view.document, let current = view.currentPage else { return }
            let words = "Page \(document.index(for: current) + 1) of \(document.pageCount)"
            DispatchQueue.main.async { self.parent.page = words }
        }
    }
}

/// The saved copy of a web page. Scripts in it are not run: it is the page as it looked, not a live one.
/// Nothing is fetched from the web while it shows: content rules block every web address except those
/// saved in the copy, so a picture that was not saved is left out instead of being fetched from the site.
private struct SavedPage: NSViewRepresentable {
    let url: URL
    let base: URL?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != url else { return }
        context.coordinator.shown = url
        let url = url
        let base = base
        let coordinator = context.coordinator
        Task { @MainActor in
            // Reading the copy and listing what it holds can take a moment for a large page.
            let (archive, rules) = await Task.detached { () -> (Data?, String) in
                let archive = url.pathExtension.lowercased() == "webarchive" ? try? Data(contentsOf: url) : nil
                return (archive, SavedPageRules.json(allowing: archive.map(SavedPageRules.addresses(inArchive:)) ?? []))
            }.value
            // Each copy compiles its own list. It is removed from the store once the view holds it, so the
            // addresses of saved pages are not left on disk outside the library.
            let store = WKContentRuleListStore.default()
            let identifier = "chirp.savedPage." + UUID().uuidString
            let list = try? await store?.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
            try? await store?.removeContentRuleList(forIdentifier: identifier)
            // Another copy was asked for meanwhile; it is loading itself.
            guard coordinator.shown == url else { return }
            guard let list else {
                // Without the rules the copy could reach the web, so it is not shown.
                Log.write("read", "a saved page was not shown: its content rules did not compile")
                return
            }
            view.configuration.userContentController.removeAllContentRuleLists()
            view.configuration.userContentController.add(list)
            if let archive {
                view.load(archive, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: base ?? url)
            } else {
                view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: URL?

        /// A link in the copy opens in the browser; the copy itself stays where it is.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// Any other file, as Quick Look shows it (a Word file's pages, rich text).
private struct QuickLookPages: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
