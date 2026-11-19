import Foundation
import Testing
@testable import ChirpCore

/// Ads and boilerplate are taken out by rule before a summary.
@Suite struct BoilerplateTests {
    @Test func aNewslettersHeaderSponsorAndFooterGo() {
        let text = """
            Sign Up | Advertise | View Online
            TLDR
            Together With Quillstack
            TLDR 2026-11-16
            Ship docs your users actually read (Sponsor)
            Quillstack turns your OpenAPI spec into a searchable docs site in under five minutes. Start a free trial today.
            Try Quillstack free
            Big Tech & Startups
            Orbital raises $410 million to build chip packaging plants in Arizona (3 minute read)
            Orbital Semiconductor has raised $410 million in a Series C led by Halvard Capital, for two plants near Phoenix.
            Lumen Mobile is laying off 600 people, around 9% of its staff, after its phone sold fewer units than forecast.
            Want to advertise in TLDR? 📰
            If your company is interested in reaching an audience of tech professionals, you may want to advertise with us.
            If you don't want to receive future editions of TLDR, please unsubscribe.
            """
        let kept = Boilerplate.strip(text)
        for gone in ["Sign Up", "Together With", "Quillstack", "Try Quillstack", "Want to advertise", "unsubscribe"] { #expect(!kept.contains(gone), "\(gone)") }
        for stays in ["TLDR 2026-11-16", "Big Tech & Startups", "Orbital Semiconductor has raised", "Lumen Mobile"] { #expect(kept.contains(stays), "\(stays)") }
    }

    @Test func anAdLabelTakesOnlyItsOwnParagraph() {
        let text = """
            How I flew to Lisbon for $212 return
            Advertisement
            Book hotels in Lisbon from $49 a night. Free cancellation on most rooms. Book now on StayFinder.
            Last month I flew from Boston to Lisbon and back for $212, including a carry-on bag.
            First, I set a fare alert on two different flight search sites in June for any date in October.
            """
        let kept = Boilerplate.strip(text)
        #expect(!kept.contains("StayFinder") && !kept.contains("Advertisement"))
        #expect(kept.contains("Last month I flew") && kept.contains("First, I set a fare alert"))
    }

    @Test func cookieNoticesSignUpBoxesAndRelatedListsGo() {
        let prose = (1...6).map { "Paragraph \($0) of the article says something useful at a fair length, as articles do." }.joined(separator: "\n")
        let text = """
            We value your privacy
            We and our partners use cookies to personalise content and ads. Click "I accept" to agree.
            I accept
            Manage settings
            \(prose)
            Sign up for our free weekly newsletter
            Get seasonal growing tips delivered to your inbox every Friday. Join 85,000 gardeners.
            Enter your email
            Subscribe
            The last paragraph of the article ends here with a full sentence about the plot.
            Related posts
            Ten easy vegetables for beginners
            Read more
            The no-dig method explained
            Read more
            """
        let kept = Boilerplate.strip(text)
        for gone in ["privacy", "cookies", "I accept", "newsletter", "85,000", "Enter your email", "Subscribe", "Related posts", "Ten easy vegetables", "Read more"] {
            #expect(!kept.contains(gone), "\(gone)")
        }
        #expect(kept.contains("Paragraph 1 of") && kept.contains("Paragraph 6 of") && kept.contains("The last paragraph"))
    }

    @Test func aFooterIsCutOnlyNearTheEndAndCodeIsNeverTouched() {
        let body = (1...8).map { "Line \($0) of the message has real news in it that the reader wants to keep." }.joined(separator: "\n")
        let mail = body + "\nSofia\nThis email and any attachments are confidential and intended solely for the addressee.\nNorthfield Logistics"
        let kept = Boilerplate.strip(mail)
        #expect(kept.contains("Line 8") && kept.contains("Sofia") && !kept.contains("confidential") && !kept.contains("Northfield"))
        // The same words at the start are not a footer (they are left for the reader).
        #expect(Boilerplate.strip("All rights reserved by the treaty.\n" + body).contains("Line 1"))
        let readme = "# Tool\n\n[![Build](https://img.shields.io/badge/build-passing-green)](https://x)\n\n```sh\n👍 1\nSubscribe\n```\n\nIt renames screenshots for you, quickly and well."
        let tidy = Boilerplate.strip(readme)
        #expect(!tidy.contains("shields.io"))
        #expect(tidy.contains("```sh\n👍 1\nSubscribe\n```"))
    }

    @Test func aDocumentIsNeverNamedAfterAnAdOrAHeaderLine() {
        #expect(Library.title(from: "Sign Up | Advertise | View Online\nTLDR\nTogether With Quillstack") == "TLDR")
        #expect(Library.title(from: "View this email in your browser\nThe Weekly Byte\nIssue 212") == "The Weekly Byte")
        #expect(Library.title(from: "From: Sofia Ramirez\nTo: Alex\nSubject: Re: Warehouse app launch — revised plan\nDate: today\n\nHi all,") == "Warehouse app launch — revised plan")
        #expect(Library.title(from: "Plain words to start with here") == "Plain words to start with here")
    }

    /// The whole test set: no checklist point loses its words to the rules, and the ads listed for each input go.
    @Test func theTestSetKeepsEveryPointAndLosesItsAds() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Fixtures/summaries").standardized
        let data = try Data(contentsOf: folder.appendingPathComponent("checklist.json"))
        let checklist = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var adsLeft: [String] = []
        for item in checklist["items"] as! [[String: Any]] {
            let file = item["file"] as! String
            let raw = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            // As the screen path does it: rules, then the page's article.
            let kept = PageText.paragraphs(PageText.article(Boilerplate.strip(raw))).lowercased()
            for point in item["points"] as! [[String: Any]] {
                for group in point["any"] as! [[String]] {
                    // Every word of the point that is in the input is still there after the rules.
                    for word in group where raw.lowercased().contains(word.lowercased()) {
                        #expect(kept.contains(word.lowercased()), "\(file): \(word) (\(point["name"] as! String))")
                    }
                }
            }
            for ad in item["ads"] as! [String] where kept.contains(ad.lowercased()) { adsLeft.append("\(file): \(ad)") }
        }
        // Ads the rules cannot see (an ad written as a plain sentence in a story) are listed here, so a change shows.
        #expect(adsLeft == [], "\(adsLeft)")
    }
}
