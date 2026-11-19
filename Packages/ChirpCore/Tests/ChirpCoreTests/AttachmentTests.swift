import Foundation
import Testing

@testable import ChirpCore

@Suite struct OfficeTextTests {
    @Test func aSlidesWordsAreReadAParagraphALine() {
        let xml = """
            <p:sld><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:rPr lang="en-GB"/><a:t>Project Kingfisher</a:t></a:r></a:p>
            <a:p><a:r><a:t>Budget: </a:t></a:r><a:r><a:t>12.50 &amp; rising</a:t></a:r></a:p><a:p><a:endParaRPr/></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
            """
        #expect(OfficeText.slide(xml) == "Project Kingfisher\nBudget: 12.50 & rising")
        #expect(OfficeText.inOrder(["slide10.xml", "slide2.xml", "slide1.xml"]) == ["slide1.xml", "slide2.xml", "slide10.xml"])
    }

    @Test func aSheetsCellsAreRead() {
        let strings = OfficeText.sharedStrings("<sst><si><t>Item</t></si><si><r><t>Unit </t></r><r><t>cost</t></r></si><si><t>Case</t></si></sst>")
        #expect(strings == ["Item", "Unit cost", "Case"])
        let sheet = """
            <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>2.5</v></c><c r="C2" t="inlineStr"><is><t>euro</t></is></c></row><row r="3"></row></sheetData></worksheet>
            """
        #expect(OfficeText.sheet(sheet, strings: strings) == "Item\tUnit cost\nCase\t2.5\teuro")
    }

    @Test func commaSeparatedFilesKeepQuotedCommas() {
        #expect(OfficeText.csv("name,cost\n\"Case, rubber\",2.5\n\n\"He said \"\"no\"\"\",1") == "name\tcost\nCase, rubber\t2.5\nHe said \"no\"\t1")
    }
}

@Suite struct AttachmentTests {
    @Test func aFileWithNoTextIsKeptAndSaidNotToBeSearchable() {
        let picture = RecordingContext.Attachment(name: "whiteboard.heic", text: "", file: "a1-whiteboard.heic")
        let deck = RecordingContext.Attachment(name: "Launch plan.pptx", text: "Project Kingfisher\nBudget 12.50", file: "b2-Launch plan.pptx")
        #expect(!picture.isSearchable && picture.kindLine == "Not searchable")
        #expect(deck.isSearchable && deck.kindLine == "PPTX")
        let context = RecordingContext(attachments: [picture, deck])
        #expect(context.attachmentText == "Launch plan.pptx\nProject Kingfisher\nBudget 12.50")
        // Saved and read back, the file's name comes with it; one saved before files were kept has none.
        #expect(RecordingContext(json: context.json).attachments == [picture, deck])
        let old = RecordingContext(json: #"{"attendees":[],"links":[],"screens":[],"attachments":[{"name":"a.pdf","text":"words"}]}"#)
        #expect(old.attachments.first?.file == nil && old.attachments.first?.isSearchable == true)
    }

    @Test func theExcerptForTheNotesIsBounded() {
        let long = String(repeating: "Kingfisher budget review. ", count: 200)
        let context = RecordingContext(attachments: [.init(name: "a.pdf", text: long), .init(name: "b.pptx", text: long), .init(name: "c.png", text: "")])
        let excerpt = context.attachmentExcerpt(limit: 1000) ?? ""
        #expect(excerpt.contains("[a.pdf]") && excerpt.contains("[b.pptx]") && !excerpt.contains("c.png"))
        #expect(excerpt.count <= 1000 + 20)
        #expect(RecordingContext().attachmentExcerpt() == nil)
        let material = MeetingText.notesMaterial(userNotes: "", points: ["Me: hello"], transcript: true, reference: excerpt)
        #expect(material.contains("<reference_files>") && material.contains("NOT said"))
        #expect(!MeetingText.notesMaterial(userNotes: "", points: ["Me: hello"], transcript: true).contains("reference_files"))
    }

    @Test func aWordInAnAttachedFileFindsItsRecordingAfterEverythingElse() throws {
        let lib = Library(store: try ChirpStore())
        let byTitle = try lib.save(SavedItem(kind: .meeting, title: "Kingfisher kickoff"))
        let bySaid = try lib.save(SavedItem(kind: .meeting, title: "Weekly sync"))
        let byFile = try lib.save(SavedItem(kind: .meeting, title: "Design review"))
        try lib.replaceSegments(itemID: bySaid.id!, with: [TranscriptSegment(itemID: 0, speaker: "Me", start: 0, end: 2, text: "Kingfisher slipped a week.")])
        try lib.setAttachmentText(itemID: byFile.id!, text: "Launch plan.pptx\nProject Kingfisher budget")
        #expect(try lib.search("kingfisher").map(\.id) == [byTitle.id!, bySaid.id!, byFile.id!])
        #expect(try lib.search("budget").first?.snippet.contains("«budget»") == true)
        // Taken away, it is no longer found; and it goes with its recording.
        try lib.setAttachmentText(itemID: byFile.id!, text: "")
        #expect(try lib.search("budget").isEmpty)
        try lib.setAttachmentText(itemID: byFile.id!, text: "budget")
        try lib.delete(byFile)
        #expect(try lib.search("budget").isEmpty)
    }

    @Test func aLibraryMadeBeforeGetsItsDocumentsIndexed() throws {
        // A library as it was before files were indexed: the document's text only in the recording's record.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-attach-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try ChirpStore(url: url, upTo: "v4")
            let context = RecordingContext(attachments: [.init(name: "plan.pdf", text: "The marmalade budget")])
            _ = try Library(store: store).save(SavedItem(kind: .meeting, title: "Sync", context: context.json))
        }
        let lib = Library(store: try ChirpStore(url: url))
        #expect(try lib.search("marmalade").count == 1)
    }

    @Test func theExportListsTheFiles() {
        let context = RecordingContext(attachments: [.init(name: "Launch plan.pptx", text: "x", file: "f")])
        let md = MeetingText.markdown(item: SavedItem(kind: .meeting, title: "Sync", context: context.json), segments: [])
        #expect(md.contains("## Files\n\n- Launch plan.pptx"))
    }
}
