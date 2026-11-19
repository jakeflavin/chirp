// Renders the share images in Site/source/*.html to PNGs in Site/assets/.
// Run from the repository root: swift Site/source/render.swift
// It uses the Mac's own WebKit, so nothing needs installing.
import AppKit
import WebKit

struct Job { let page: String; let png: String; let width: Int; let height: Int; let scale: Int }

let jobs: [Job] = [
    Job(page: "og.html", png: "og.png", width: 1200, height: 630, scale: 1),
    Job(page: "social-preview.html", png: "social-preview.png", width: 1280, height: 640, scale: 1),
    Job(page: "readme-banner.html", png: "readme-banner.png", width: 1440, height: 480, scale: 2),
] + ["dictate", "meetings", "writing-checks", "read-aloud", "summarize", "notes-and-search"].map {
    Job(page: "feature-\($0).html", png: "feature-\($0).png", width: 1200, height: 630, scale: 2)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Site/source")
let assets = root.appendingPathComponent("Site/assets")

final class Renderer: NSObject, WKNavigationDelegate {
    private var queue: [Job]
    private var window: NSWindow?
    private var view: WKWebView?

    init(_ jobs: [Job]) { queue = jobs }

    func next() {
        guard let job = queue.first else { NSApp.terminate(nil); return }
        let frame = NSRect(x: 0, y: 0, width: job.width, height: job.height)
        let view = WKWebView(frame: frame)
        view.appearance = NSAppearance(named: .aqua)
        view.navigationDelegate = self
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        self.view = view
        self.window = window
        let page = source.appendingPathComponent(job.page)
        view.loadFileURL(page, allowingReadAccessTo: root.appendingPathComponent("Site"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give images and fonts a moment to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.capture() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("Failed: \(queue.first?.page ?? "?"): \(error.localizedDescription)"); exit(1)
    }

    private func capture() {
        let job = queue.removeFirst()
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: job.width, height: job.height)
        config.snapshotWidth = NSNumber(value: job.width * job.scale)
        view?.takeSnapshot(with: config) { image, error in
            guard let image else { print("Snapshot failed: \(error?.localizedDescription ?? "")"); exit(1) }
            let w = job.width * job.scale, h = job.height * job.scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            let out = assets.appendingPathComponent(job.png)
            try! rep.representation(using: .png, properties: [:])!.write(to: out)
            print("Wrote Site/assets/\(job.png) (\(w)×\(h))")
            self.window?.close()
            self.next()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(jobs)
DispatchQueue.main.async { renderer.next() }
app.run()
