# Testing

Chirp has four kinds of checks. Run the first two before every pull request.

| Check | Command | Time | Needs |
|---|---|---|---|
| Unit tests | `cd Packages/ChirpCore && swift test` | seconds | nothing |
| Grammar library tests | `cd Rust/chirp-harper && cargo test --release --lib` | under a minute | Rust |
| End-to-end checks | `Scripts/e2e.sh` | about 30 minutes | a Release build, downloaded models |
| Checks in real apps | `Scripts/preflight.sh` | a few minutes | permissions, an unlocked Mac, sound |

CI runs the unit tests and an unsigned Release build on every pull request (`.github/workflows/ci.yml`).

## Unit tests

```sh
cd Packages/ChirpCore && swift test
swift test --filter LibraryTests          # one suite
swift test --filter "LibraryTests/savesWithTitleAndLists"
```

The tests are in `Packages/ChirpCore/Tests/ChirpCoreTests`. They use Swift Testing and an in-memory
database, need no models and no permissions, and run in a few seconds. `ChirpML` has no unit tests: model
behaviour is covered end to end.

What they cover:

| Area | Files |
|---|---|
| Database, library, migrations, search | `LibraryTests`, `SearchTests`, `DocumentTests`, `NoteTests`, `AttachmentTests`, `CorrectionTests`, `DataResetTests` |
| Dictation clean-up and formatting | `TextTests`, `DictationFlowTests`, `InsertionTests`, `EngineTests`, `StyleDefaultsTests` |
| Writing checks and rewrites | `ProofreadingTests`, `RewriteCheckTests`, `UnderlineLookTests`, `FieldGuardTests`, `MarkdownLinesTests`, `NoteListsTests` |
| Reading aloud | `ReadingTests`, `SpeechTextTests`, `WordTimingTests`, `ReadMarksTests`, `CitationTests`, `TableReadingTests` |
| Meetings and recordings | `MeetingTests`, `RecordingDiskTests`, `RecordingGapsTests`, `RecordingLinesTests`, `RecordingRebuildTests`, `MediaLinksTests`, `TurnGateTests` |
| Summaries | `SummaryTests`, `SourceWordsTests`, `BoilerplateTests` |
| Features, Home, perch, shortcuts, models | `FeaturesTests`, `HomeLinesTests`, `PerchArrangementTests`, `ShortcutKeysTests`, `ModelChoiceTests`, `RestartLimitTests` |
| Wide coverage of many helpers, and fixed bugs | `CoverageTests`, `RegressionTests`, `BlockingBugTests` |

### Adding a unit test

1. Put the logic you want to test in `ChirpCore`, not in the app.
2. Add a `@Test` to the suite for that subject, or a new file `<Subject>Tests.swift`:

   ```swift
   import Foundation
   import Testing

   @testable import ChirpCore

   @Suite struct DocumentRowsTests {
       @Test func aWebPageIsKnownByItsSite() {
           let item = SavedItem(kind: .document, source: "https://www.example.com/post")
           #expect(DocumentRows.host(item.source) == "example.com")
       }
   }
   ```

3. Name the test after the behaviour, as a phrase.
4. Use `try ChirpStore()` for a database in memory. For a migration, open a temporary file at the step
   before with `ChirpStore(url:upTo:)` (see [DATA-MODEL.md](DATA-MODEL.md#adding-a-migration)).
5. Use made-up names and text. Never real people, addresses or text copied from a real site.
6. A test of a fixed bug says what the bug did in its name or a one-line comment, not where it was reported.

## End-to-end checks

```sh
# build Release first (see DEVELOPMENT.md), then:
Scripts/e2e.sh                                   # every section
Scripts/e2e.sh path/to/Chirp.app                 # another build
ONLY=read Scripts/e2e.sh                         # one section
CHECK_WAIT=20 Scripts/e2e.sh                     # a slower Mac: each check waits up to 20 s (default 10)
CHIRP_LOCK=<folder> Scripts/e2e.sh               # hold this folder as a lock for the run, so heavy jobs take turns
SKIP_LLM=1 Scripts/e2e.sh                        # leave out the summaries section
```

What it does:

1. Copies the app (default `.dd/Build/Products/Release/Chirp.app`) to a temporary folder, gives the copy its
   own bundle id and signs it ad hoc. The installed Chirp and its preferences are not touched.
2. Launches the copy with `--debug-hooks --ui-testing --skip-onboarding --no-global-shortcuts`, and for each
   scenario feeds recorded audio, a call's other side or a screen picture with `--feed-audio`,
   `--feed-system-audio` and `--feed-screen`.
3. Drives it with `chirp://debug/…` links and reads `chirp://debug/state` back as JSON.
4. Prints `ok` or `FAIL` for each check, with the state values a failed check looked at, then
   `N passed, M failed`. It exits 0 only when every check passed.

It needs no permissions and makes no sound. It uses the real models, so the first run downloads them. It
does not touch other apps, the microphone or the speakers: `Scripts/preflight.sh` does that.

Sections (`ONLY=` values):

| Section | What it checks |
|---|---|
| `speak` | Clean-up of a dictation, learning a correction, the hold key and shortcut, that dictation never loads the language model, the shortcut layout |
| `record` | A two-sided meeting with notes and a screen picture, a voice note, people in one room, attaching a document, recovery of a recording cut short, the Mac's own sound not written twice, two jobs at once, a stuck step, calls on the Mac |
| `write` | Checks in the editor, the sentence bird, snippets as you type, style by app, a note's one button |
| `read` | Importing documents, the voice, playback, Say it as |
| `documents` | What is kept with a document, pins and folders, the summary panel and copying, the reading place, a transcribed link |
| `remember` | Search |
| `notes` | A note in the perch, a voice note as an editable note, lists, Notes and Meetings as separate switches, the perch's arrangement |
| `home` | Home, the menu bar, onboarding, a dropped file, work in progress, stopping notes while they are written |
| `summaries` | Ads left out, a paper's overview, an email named by its subject, the sentence checker or the rule check without it |

The test copy keeps its preferences under its own bundle id. A run cut short while features were switched
off can leave them off for the next run; delete that copy's preferences with `defaults delete <its bundle id>`.

### Adding an end-to-end check

1. If the app does not yet expose what you need, add a debug link (`LinkHandler.commands`) or a value to
   `state` (`LinkHandler.stateProviders`) in the feature's controller. Both work only with `--debug-hooks`.
2. Add steps to the right section of `Scripts/e2e.sh`:

   ```sh
   cmd "read-file?path=$ROOT/Fixtures/article.txt"; sleep 1
   cmd read-play
   waitval "d['read']['index'] >= 1" 90
   check "moves on to the next sentence" "d['read']['index'] >= 1 and d['read']['playing']"
   ```

   `check` takes a name and a Python expression over `d`, the state JSON. It retries until the expression
   is true or `CHECK_WAIT` seconds pass. `waitval` waits longer for slow work (a model loading) without
   counting as a check.
3. Keep each section able to run alone with `ONLY=`.

## UI tests

`App/UITests/ChirpUITests.swift` is an XCTest UI test target in the `Chirp` scheme. It launches the app with
`--ui-testing --skip-onboarding` and looks for elements by accessibility identifier.

```sh
xcodebuild test -project Chirp.xcodeproj -scheme Chirp -destination 'platform=macOS,arch=arm64' -derivedDataPath .dd
```

It needs a signed build that macOS lets the test runner control. Prefer an end-to-end check for new behaviour.

## Checks in real apps

`Scripts/preflight.sh [path to Chirp.app]` runs the everyday flows for real: dictating into TextEdit with
the shortcut, underlining and fixing misspellings there, reading a selection aloud, and recording the
microphone and call audio with sound playing. It needs:

- the Mac unlocked and awake;
- Chirp allowed Microphone, Accessibility and call audio;
- Accessibility for the terminal that runs the script (it presses keys through `Scripts/keys.swift`).

It opens scratch documents in TextEdit, closes only those at the end, and plays about 25 seconds of a
recorded meeting out loud. A running Chirp is stopped first.

## Fixtures

All test inputs are in `Fixtures/` (see `Fixtures/README.md`). They are made up or freely licensed. The spoken clips
are synthetic voices, made by `Scripts/make-test-audio.py`: if you change a line there, change the e2e checks that
look for its words.

| Fixture | Used by |
|---|---|
| `dictation1.wav` | e2e `speak`, `record`, `documents`, `notes`; preflight |
| `names.wav` | e2e `speak`: a name misheard, corrected, then spelled right |
| `meeting-me.wav`, `meeting-them.wav` | e2e `record`, `remember`, `home`: the two sides of a meeting; preflight plays `meeting-them.wav` |
| `echo-me.wav`, `echo-them.wav` | e2e `record`: the Mac's own sound heard by the microphone |
| `screen.png` | e2e `record`: the window read during a recording |
| `agenda.txt` | e2e `record`, `home`: a document attached to a recording |
| `article.txt`, `article.pdf`, `article.docx`, `article.html` | e2e `read`, `remember`, `home`: one text in four formats |
| `book.epub`, `book-parts.epub` | e2e `read`, `home`: chapters, and a book with front matter |
| `documents/page/` | e2e `documents`: a saved web page with a picture and a summary |
| `documents/rich-text.rtf`, `documents/markdown-note.md` | e2e `documents`: formatting kept on import |
| `documents/rich-text.html` | Trying writing checks and reading by hand in other apps |
| `summaries/s*.txt`, `summaries/s*.md` | `SourceWordsTests`, `BoilerplateTests`, e2e `summaries` |
| `summaries/checklist.json` | `BoilerplateTests`: the points each summary must have and the phrases it must not |
| `summaries/LICENSES.txt` | Where the summary inputs came from |

Add a fixture only with the check that uses it, and list it here.
