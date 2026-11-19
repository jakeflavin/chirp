import Foundation
import Testing

@testable import ChirpCore

/// Where the sentence and word being read are marked in the text they came from, and whether the page
/// follows. The page here is made the way `ReadController.pageText` makes
/// one from another app: a piece of text for each run of plain words, link or bold, joined with a space
/// inside a block, a tab between the cells of a row and a line break between blocks. A picture has no text.
@Suite struct ReadMarksTests {
    /// One block of the page: its pieces of text (a paragraph with a link in it is three), or a picture.
    private enum Block {
        case text([String])
        case row([String])
        case picture
    }

    /// A page shaped like a blog post: links and bold inside sentences, pictures between paragraphs with
    /// and without captions, a table, numbers, and sentences heavy with punctuation.
    private static let page: [Block] = [
        .text(["Fourth Wing recap: chapters 1 to 4"]),
        .text(["The book opens on the salt flats outside ", "Caer Mathen", ", where the caravan has waited nine days for a guide."]),
        .text(["The guide who finally arrives is ", "Ysolde Varrick", " (sixteen, and already owed money by half the company); she agrees to take them across for a third of the cargo."]),
        .picture,
        .text(["The salt flats at dawn. Photo: the author."]),
        .text(["By the end of chapter four the crossing is half done and two of the 14 wagons are gone. ", "Nobody", " blames the guide yet."]),
        .picture,
        .text(["“Wait,” she said, “is that really the well at Orrin? It can't be: we left it 3.5 days ago!”"]),
        .text(["Pace"]),
        .row(["Week", "Distance", "Pace"]),
        .row(["1", "5K", "6:10"]),
        .row(["2", "10K", "5:58"]),
        .text(["The entry fee is $45, or $412 for a team of 10, and the race is on 12 March 2027."]),
        .text(["It cost about ", "$5K", " to put on, which the club (est. 1998) raised itself; the rest came from ", "the council", "."]),
        .picture,
        .picture,
        .text(["The second part slows down. Most of it is one long night at the well, and the argument about who drinks first. The second part slows down."]),
    ]

    /// The page's text and its pieces, as gathered from another app.
    private static func gathered() -> (whole: String, runs: [(range: NSRange, text: String)]) {
        var joined = ""
        var runs: [(NSRange, String)] = []
        for block in page {
            switch block {
            case .picture: continue
            case .text(let pieces):
                for (n, piece) in pieces.enumerated() {
                    if !joined.isEmpty { joined += n == 0 ? "\n" : " " }
                    runs.append((NSRange(location: joined.utf16.count, length: piece.utf16.count), piece))
                    joined += piece
                }
            case .row(let cells):
                for (n, cell) in cells.enumerated() {
                    if !joined.isEmpty { joined += n == 0 ? "\n" : "\t" }
                    runs.append((NSRange(location: joined.utf16.count, length: cell.utf16.count), cell))
                    joined += cell
                }
            }
        }
        return (joined, runs)
    }

    /// The sentences as they are read out: the page's text made into paragraphs and cleaned, as it is before reading.
    private static func read(_ whole: String) -> [ReadingSentence] {
        ReadingText.sentences(ReadingText.clean(PageText.paragraphs(whole)))
    }

    /// How many words of the page get a mark that covers exactly that word, the old way and the new.
    private static func tally() -> (words: Int, oldRight: Int, oldWrong: Int, newRight: Int, newWrong: Int, sentences: Int, found: Int) {
        let (whole, _) = gathered()
        let source = whole as NSString
        var words = 0, oldRight = 0, oldWrong = 0, newRight = 0, newWrong = 0, found = 0
        var after = 0
        let sentences = read(whole)
        for sentence in sentences {
            guard let hit = ReadMarks.find(sentence.text, in: whole, range: NSRange(location: after, length: source.length - after), backwards: false) else { continue }
            found += 1
            after = NSMaxRange(hit.range)
            let ns = sentence.text as NSString
            let ranges = ReadingText.wordRanges(sentence.text)
            let placed = ReadMarks.words(of: sentence.text, in: whole, found: hit.range)
            for (n, range) in ranges.enumerated() {
                words += 1
                let word = ns.substring(with: range)
                // Before: a word was marked only in a sentence found character for character, at its place
                // counted from the start of the sentence.
                if hit.exact {
                    let old = NSRange(location: hit.range.location + range.location, length: range.length)
                    if NSMaxRange(old) <= source.length, source.substring(with: old) == word { oldRight += 1 } else { oldWrong += 1 }
                }
                if let mark = placed[n] {
                    if source.substring(with: mark) == word { newRight += 1 } else { newWrong += 1 }
                }
            }
        }
        return (words, oldRight, oldWrong, newRight, newWrong, sentences.count, found)
    }

    @Test func everyWordOfThePageIsMarkedOnItself() {
        let t = Self.tally()
        print("READ-MARKS page: \(t.sentences) sentences, \(t.found) found; \(t.words) words; before: \(t.oldRight) marked right, \(t.oldWrong) wrong, \(t.words - t.oldRight - t.oldWrong) not marked; after: \(t.newRight) right, \(t.newWrong) wrong, \(t.words - t.newRight - t.newWrong) not marked")
        #expect(t.found == t.sentences)
        #expect(t.newWrong == 0)
        #expect(t.newRight == t.words)
        #expect(t.oldRight < t.newRight)
    }

    @Test func aWordIsFoundAfterTheOneBeforeIt() {
        let whole = "Intro line\nThe second part slows down.  The second part ends."
        let sentence = "The second part ends."
        let hit = ReadMarks.find(sentence, in: whole, range: NSRange(location: 38, length: (whole as NSString).length - 38), backwards: false)
        #expect(hit != nil)
        let marks = ReadMarks.words(of: sentence, in: whole, found: hit!.range)
        #expect(marks.compactMap { $0 }.map { (whole as NSString).substring(with: $0) } == ["The", "second", "part", "ends."])
        #expect(marks.first??.location == 40)
    }

    @Test func aSentenceSplitByALinkIsStillMarkedWordByWord() {
        // "outside " + " " + "Caer Mathen" + " " + ", where": two spaces in the source, one in what is read.
        let whole = "The book opens outside  Caer Mathen , where the caravan waits."
        let sentence = "The book opens outside Caer Mathen , where the caravan waits."
        let hit = ReadMarks.find(sentence, in: whole, range: NSRange(location: 0, length: (whole as NSString).length), backwards: false)
        #expect(hit?.exact == false)
        let marks = ReadMarks.words(of: sentence, in: whole, found: hit!.range)
        #expect(marks.allSatisfy { $0 != nil })
        #expect((whole as NSString).substring(with: marks[4]!) == "Caer")
        #expect((whole as NSString).substring(with: marks[5]!) == "Mathen")
    }

    @Test func aWordThatIsNotThereIsNotMarkedAndTheRestStillAre() {
        let whole = "We left it 3.5 days ago and came back."
        let sentence = "We left it three days ago and came back."
        let marks = ReadMarks.words(of: sentence, in: whole, found: NSRange(location: 0, length: (whole as NSString).length))
        #expect(marks[3] == nil)
        #expect((whole as NSString).substring(with: marks[4]!) == "days")
        #expect((whole as NSString).substring(with: marks[8]!) == "back.")
    }

    @Test func aPlaceCountedDifferentlyIsSettledOnTheWord() {
        // The piece's text as handed over, and as the app counts it (the line break and indent are one space on the page).
        let given = "The guide who finally\n    arrives is Ysolde Varrick, sixteen."
        let counted = "The guide who finally arrives is Ysolde Varrick, sixteen."
        let at = (given as NSString).range(of: "Ysolde")
        // Counted from the text as given, the mark lands four characters late: "de Var".
        #expect((counted as NSString).substring(with: at) != "Ysolde")
        let settled = ReadMarks.settled("Ysolde", at: at, in: counted)
        #expect(settled.map { (counted as NSString).substring(with: $0) } == "Ysolde")
        // Where the two agree nothing moves, and a word that is not there gets no mark.
        #expect(ReadMarks.settled("guide", at: NSRange(location: 4, length: 5), in: counted) == NSRange(location: 4, length: 5))
        #expect(ReadMarks.settled("Orrin", at: at, in: counted) == nil)
        // Of the same word twice, the nearer one.
        #expect(ReadMarks.settled("the", at: NSRange(location: 22, length: 3), in: "the well and the wall and the end") == NSRange(location: 26, length: 3))
    }

    @Test func aPieceCountedDifferentlyBeforeAndAfter() {
        // Every word of a paragraph whose source is wrapped and indented, counted the old way and settled.
        let given = "By the end of chapter four\n      the crossing is half done\n      and two of the 14 wagons are gone.\n      Nobody blames the guide yet."
        let counted = given.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var before = 0, after = 0, total = 0
        for range in ReadingText.wordRanges(given) {
            total += 1
            let word = (given as NSString).substring(with: range)
            if NSMaxRange(range) <= (counted as NSString).length, (counted as NSString).substring(with: range) == word { before += 1 }
            if let moved = ReadMarks.settled(word, at: range, in: counted), (counted as NSString).substring(with: moved) == word { after += 1 }
        }
        print("READ-MARKS counted differently: \(total) words; before \(before) marked on the word, after \(after)")
        #expect(after == total)
        #expect(before < total / 2)
    }

    @Test func thePageKeepsFollowingPastAPicture() {
        // A sentence under a picture: the first request leaves it out of view (the picture is still loading),
        // the second brings it in. Then five more sentences, each below the fold when reading reaches it.
        var follow = ReadFollow()
        var asked: [Bool] = []
        asked.append(follow.reached(inView: true))  // in view: nothing to ask
        asked.append(follow.reached(inView: false))  // under the picture: asked for
        asked.append(follow.looked(inView: false, sinceRequest: 0.3))  // given a moment
        asked.append(follow.looked(inView: false, sinceRequest: 0.7))  // still not there: asked again
        #expect(asked == [false, true, false, true])
        #expect(follow.following)
        asked.append(follow.looked(inView: true, sinceRequest: 0.3))
        var followed = 0
        for _ in 0..<5 {
            if follow.reached(inView: false) { followed += 1 }
            _ = follow.looked(inView: true, sinceRequest: 0.4)
        }
        #expect(followed == 5)

        // The old rule, for the number: whatever was out of view 0.6 s after a request stopped the following.
        var oldFollowing = true
        var oldFollowed = 0
        oldFollowing = false  // the sentence under the picture was out of view at the look 0.7 s later
        for _ in 0..<5 where oldFollowing { oldFollowed += 1 }
        print("READ-MARKS follow past a picture: before \(oldFollowed) of 5 later sentences scrolled to, after \(followed) of 5")
    }

    @Test func scrollingAwayStillStopsItAndScrollingBackStartsIt() {
        var follow = ReadFollow()
        _ = follow.reached(inView: true)
        // The reader scrolls up to look at something: it was in view, now it is not.
        let chased = follow.looked(inView: false, sinceRequest: 5)
        #expect(!chased)
        #expect(follow.following == false)
        // The next sentence is not chased.
        let next = follow.reached(inView: false)
        #expect(!next)
        // Back in view: following again.
        _ = follow.looked(inView: true, sinceRequest: 5)
        #expect(follow.following)
        let again = follow.reached(inView: false)
        #expect(again)
    }

    @Test func aPageThatWillNotMoveIsAskedThreeTimesAndNoMore() {
        var follow = ReadFollow()
        var asked = [follow.reached(inView: false)]
        asked.append(follow.looked(inView: false, sinceRequest: 1))
        asked.append(follow.looked(inView: false, sinceRequest: 1))
        asked.append(follow.looked(inView: false, sinceRequest: 1))
        #expect(asked == [true, true, true, false])
        // It has not given up for good: the next sentence is asked for.
        let next = follow.reached(inView: false)
        #expect(next)
    }
}

/// "Say it as": which words are offered while reading.
@Suite struct SayItAsTests {
    @Test func theNamesJustSpokenAreOfferedTheLastOnePicked() {
        let sentences = [
            "Chepngetich won in Valencia last year.",
            "The record still belongs to Kipchoge, who ran it in Berlin.",
        ]
        // Reading has reached "Kipchoge,".
        let spoken = SayItAs.spokenWords(sentences: sentences, upTo: 6)
        #expect(SayItAs.candidates(spoken: spoken) == ["Chepngetich", "Valencia", "Kipchoge"])
    }

    @Test func aCapitalThatOnlyStartsASentenceIsNotAName() {
        let spoken = SayItAs.spokenWords(sentences: ["Nobody blames the guide yet, least of all Ysolde."], upTo: 9)
        let offered = SayItAs.candidates(spoken: spoken)
        #expect(offered.last == "Ysolde")
        // "The" starts a sentence and is never offered as a name.
        let plain = SayItAs.candidates(spoken: SayItAs.spokenWords(sentences: ["The guide arrives with Ysolde."], upTo: 5))
        #expect(!plain.contains("The"))
    }

    @Test func withNoNamesTheLongerRecentWordsAndTheSpokenOne() {
        let spoken = SayItAs.spokenWords(sentences: ["the crossing is half done and two of the wagons are gone"], upTo: 10)
        let offered = SayItAs.candidates(spoken: spoken)
        #expect(offered.last == "wagons")
        #expect(offered.contains("crossing"))
        #expect(offered.count <= 3)
    }

    @Test func theNewestNameIsPickedEvenWhenTheVoiceHasMovedOn() {
        // The button is pressed a few words after the name was said.
        let spoken = SayItAs.spokenWords(sentences: ["The guide who finally arrives is Ysolde Varrick, sixteen and already owed money by half the company."], upTo: 17)
        let offer = SayItAs.offer(spoken: spoken)
        #expect(offer.words == ["Ysolde", "Varrick", "company"])
        #expect(offer.picked == "Varrick")
        // With no name heard, the word being spoken.
        #expect(SayItAs.offer(spoken: SayItAs.spokenWords(sentences: ["the crossing is half done"], upTo: 4)).picked == "half")
    }

    // The word the mark is on is offered first and picked, not a name heard earlier.
    @Test func theMarkedWordIsPickedWithTheWordsBeforeIt() {
        let sentence = "Typing it out felt slow, so I searched through Stack Overflow for an answer."
        let words = ReadingText.wordRanges(sentence)
        let overflow = words.firstIndex { (sentence as NSString).substring(with: $0) == "Overflow" }!
        let offer = SayItAs.offer(sentence: sentence, marked: overflow)
        // The two-word name is one chip, picked, and last; the words before it are the other chips.
        #expect(offer.picked == "Stack Overflow")
        #expect(offer.words == ["slow", "searched", "Stack Overflow"])
        #expect((sentence as NSString).substring(with: offer.range!) == "Stack Overflow")
        // The mark on "Stack" gives the same name.
        #expect(SayItAs.offer(sentence: sentence, marked: overflow - 1).picked == "Stack Overflow")
    }

    @Test func aPlainMarkedWordIsPickedEvenWithANameBeforeIt() {
        let sentence = "The guide who finally arrives is Ysolde Varrick, sixteen and already owed money."
        let words = ReadingText.wordRanges(sentence)
        let sixteen = words.firstIndex { (sentence as NSString).substring(with: $0) == "sixteen" }!
        let offer = SayItAs.offer(sentence: sentence, marked: sixteen)
        #expect(offer.picked == "sixteen")
        // A comma breaks a name: "Varrick," and "sixteen" are not joined.
        #expect(offer.words.last == "sixteen")
        // The name before the comma is one chip.
        #expect(offer.words.contains("Ysolde Varrick"))
    }

    // A capitalised two-word name the mark has moved past is still one chip.
    @Test func aNameTheMarkHasPassedIsOneChip() {
        let sentence = "I first heard of it at a Stack Overflow meetup in town."
        let words = ReadingText.wordRanges(sentence)
        let meetup = words.firstIndex { (sentence as NSString).substring(with: $0) == "meetup" }!
        let offer = SayItAs.offer(sentence: sentence, marked: meetup)
        #expect(offer.picked == "meetup")
        #expect(offer.words.contains("Stack Overflow"))
        #expect(!offer.words.contains("Stack") && !offer.words.contains("Overflow"))
        #expect(offer.words.last == "meetup")
        // From the sentence before, too.
        let next = SayItAs.offer(sentence: "Nobody came.", marked: 0, before: "We met at the Stack Overflow meetup.")
        #expect(next.words.contains("Stack Overflow"))
        // Words with no capital, or split by a comma, stay apart.
        #expect(SayItAs.chips("Paris, London and rome", upTo: nil) == ["rome", "and", "London", "Paris"])
    }

    @Test func nearTheStartTheSentenceBeforeFillsIn() {
        let offer = SayItAs.offer(sentence: "Kipchoge won again.", marked: 0, before: "The record fell in Berlin.")
        #expect(offer.picked == "Kipchoge")
        #expect(offer.words == ["fell", "Berlin", "Kipchoge"])
        // Names do not join across a full stop, and a sentence-start capital alone is still the marked word.
        let start = SayItAs.offer(sentence: "Berlin. Valencia is next.", marked: 0)
        #expect(start.picked == "Berlin")
    }

    @Test func aWordIsOfferedBare() {
        #expect(SayItAs.bare("“Ysolde’s”") == "Ysolde")
        #expect(SayItAs.bare("(Kipchoge),") == "Kipchoge")
        let spoken = SayItAs.spokenWords(sentences: ["It was Ysolde's turn."], upTo: 3)
        #expect(SayItAs.candidates(spoken: spoken).last == "Ysolde")
    }
}

/// A word box that is not around its word is not drawn.
@Suite struct WordBoxTests {
    /// A line of text in a font where each character is 10 points wide and the line 20 points tall, as an
    /// app would report it; `wrong` overrides the answer for some ranges, the way Safari answered for
    /// "Overflow" with the box of "verfl".
    struct FakePage {
        let text: String
        var wrong: [NSRange: CGRect] = [:]
        func box(_ r: NSRange) -> [CGRect] {
            if let bad = wrong[r] { return [bad] }
            return [CGRect(x: 100 + CGFloat(r.location) * 10, y: 300, width: CGFloat(r.length) * 10, height: 20)]
        }
        var words: [NSRange?] { ReadingText.wordRanges(text).map { $0 } }
        func place(of word: String) -> Int {
            ReadingText.wordRanges(text).firstIndex { (text as NSString).substring(with: $0) == word }!
        }
    }

    @Test func theVerflBoxIsNotDrawn() {
        var page = FakePage(text: "I searched through Stack Overflow for an answer.")
        let overflow = (page.text as NSString).range(of: "Overflow")
        // Safari's box: one letter late ("v"), ending after "fl" (the ligature), so "ow" is cut off.
        let verfl = (page.text as NSString).range(of: "verfl")
        page.wrong[overflow] = CGRect(x: 100 + CGFloat(verfl.location) * 10, y: 300, width: CGFloat(verfl.length) * 10, height: 20)
        let result = WordBox.check(place: page.place(of: "Overflow"), words: page.words, boxes: page.box)
        #expect(result.verdict != .ok)
        #expect(result.verdict == .startsInside)
        // The words around it, measured the same way, are fine.
        #expect(WordBox.check(place: page.place(of: "Stack"), words: page.words, boxes: page.box).verdict == .ok)
        #expect(WordBox.check(place: page.place(of: "for"), words: page.words, boxes: page.box).verdict == .ok)
    }

    @Test func eachWayABoxCanBeWrong() {
        var page = FakePage(text: "one two three four five")
        let three = (page.text as NSString).range(of: "three")
        let at = page.place(of: "three")
        let right = page.box(three)[0]
        // Stops short: only "thr".
        page.wrong[three] = CGRect(x: right.minX, y: 300, width: 30, height: 20)
        #expect(WordBox.check(place: at, words: page.words, boxes: page.box).verdict == .stopsShort)
        // The end of the word before and the start of this one.
        page.wrong[three] = CGRect(x: right.minX - 20, y: 300, width: 50, height: 20)
        #expect(WordBox.check(place: at, words: page.words, boxes: page.box).verdict == .overlaps)
        // Narrow, with no neighbour on the line to compare with: the line's own width tells.
        #expect(WordBox.verdict(box: CGRect(x: 0, y: 0, width: 20, height: 20), length: 8, previous: nil, next: nil, perCharacter: 10) == .tooNarrow)
        // No box at all.
        page.wrong[three] = .zero
        #expect(WordBox.check(place: at, words: page.words, boxes: page.box).verdict == .missing)
        // The first word of a line has no word before it on the line; the next line's word is not compared.
        var wrapped = FakePage(text: "one two")
        let two = (wrapped.text as NSString).range(of: "two")
        wrapped.wrong[two] = CGRect(x: 100, y: 330, width: 30, height: 20)
        #expect(WordBox.check(place: 1, words: wrapped.words, boxes: wrapped.box).verdict == .ok)
    }
}
