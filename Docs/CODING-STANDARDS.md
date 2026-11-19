# Coding standards

These are the rules Chirp's code follows. They are written for people and for coding agents. When the
code and this page disagree, follow this page and fix the code in the same change if it is small.

Related pages: [ARCHITECTURE.md](ARCHITECTURE.md), [DEVELOPMENT.md](DEVELOPMENT.md) (build and run), [TESTING.md](TESTING.md),
[DATA-MODEL.md](DATA-MODEL.md), and [DESIGN.md](DESIGN.md) (visual design, including colour).

## The short version

- Pure logic goes in `ChirpCore`, with a test. Model code goes in `ChirpML`. Views and system glue go in `App`.
- Model work runs only in a helper process. The app process never loads a model.
- UI state is a `@MainActor @Observable final class`. Views read it with `@Environment(Type.self)`.
- Log with `Log.write(area, message)`. Never log what the user said, typed, selected or read.
- Icons come from Chirp's own set: `Image("chirp.name")`. Never SF Symbols.
- User-facing text is plain and short.
- Comments explain why, in plain sentences, and stand on their own.

## Swift style and naming

| Rule | Example |
|---|---|
| Four spaces, no tabs. Keep lines under about 140 characters. | |
| Types are `UpperCamelCase` nouns for what they are. | `DictationController`, `RecordingContext`, `DocumentExtra` |
| Functions and properties are `lowerCamelCase` and read as English at the call site. | `library.setPinned(id:_:)`, `set.needs(.language)`, `item.deleteWarning` |
| Booleans read as a statement. | `isLoaded`, `speechPrepared`, `shows(_:)`, `takesDrop(audio:)` |
| Name things after what the user sees, not after how they work. | `Feature.write` is titled "Writing checks" |
| A namespace of static helpers is a caseless `enum`. | `enum DocumentRows`, `enum DataReset`, `enum SemanticSearch` |
| Imports are sorted alphabetically, one per line. | `import AppKit`, `import ChirpCore`, `import SwiftUI` |
| `final class` unless a class is meant to be subclassed. | |
| Use `if`/`switch` expressions for short mappings. | `var title: String { switch self { case .dictate: "Dictate" … } }` |
| Prefer `guard … else { return }` for early exits. | |
| Enum cases saved to disk or preferences are never renamed. Their raw value is the stored name. | `ItemKind`, `Feature`, `Formality` |

Access control:

- `ChirpCore` and `ChirpML` mark what the app uses as `public`. Everything else stays internal or `private`.
  Tests reach internals with `@testable import ChirpCore`.
- In `App`, leave declarations internal (the default) and mark helpers `private`.
- Do not use `fileprivate` unless two types in one file must share a helper.

## File and type layout

- One main type per file, named after the file: `DictationController.swift` holds `DictationController`.
  Small types that only serve the main type (its row view, its state enum, its panel) may live in the same
  file below it.
- A type that is used from more than one place gets its own file. Do not hide general helpers inside a
  feature file.
- Use `// MARK: Section` inside long types to group members (`// MARK: Items`, `// MARK: Search`).
- Split a file that grows past about 800 lines along its `MARK` sections, using extensions in new files
  named `Type+Part.swift`.
- `App/Sources` is grouped by feature: `Speak`, `Record`, `Notes`, `Write`, `Read`, `Remember`, `Perch`,
  `Onboarding`, `Shell` (window, menu bar, settings, app), `Services` (system glue), `Design` (shared views
  and tokens).
- `ChirpCore/Sources/ChirpCore` is grouped by subject: `Engine`, `Store`, `Text`, `Reading`, `Meetings`, `Home`.

## Modules and dependencies

```
App (Chirp target) ──► ChirpML ──► ChirpCore ──► GRDB
        │                 └──► TranscribeCpp, FluidAudio, MLX, swift-transformers, swift-huggingface
        ├──► ChirpCore
        ├──► KeyboardShortcuts, Sparkle
        └──► ChirpHarper (Rust static library, Rust/include)
```

| Module | Holds | May import | Must not import |
|---|---|---|---|
| `ChirpCore` | Data model and store, text rules, reading and meeting logic, feature switch logic, prompts | Foundation, GRDB, CoreGraphics | SwiftUI, AppKit, ChirpML, any ML library |
| `ChirpML` | The app's side of each model, the helper processes and their engines | ChirpCore, TranscribeCpp, FluidAudio, MLX libraries, CoreML | SwiftUI, AppKit |
| `App` | Views, controllers, AppKit and system services, updates, debug links | ChirpCore, ChirpML, KeyboardShortcuts, Sparkle, ChirpHarper, Apple frameworks | GRDB, MLX, FluidAudio, TranscribeCpp directly |

- The app reads and writes the database only through `ChirpStore`, `Library` and `PersonalLanguage`.
- The app reaches a model only through its `ChirpML` front: `Transcriber`, `LanguageModel`, `Embedder`,
  `Voice`, `SpeakerLabeler`, `FactChecker`.
- If logic can be tested without a window, a model or the system, it belongs in `ChirpCore`.
- New package dependencies need a reason in the pull request. Pin them in `Package.swift` or `project.yml`.

## Concurrency

The packages build in the Swift 6 language mode. Write all new code so it compiles cleanly with strict
concurrency checking.

| Kind of code | Pattern |
|---|---|
| UI state and controllers | `@MainActor @Observable final class` |
| A model's front in `ChirpML` | `public actor` (`LanguageModel`, `Transcriber`, `Embedder`, `Voice`) |
| Database access | `final class …: Sendable` holding GRDB's `DatabaseQueue` (`ChirpStore`, `Library`, `PersonalLanguage`) |
| Pure logic | `struct` or caseless `enum`, `Sendable` |
| Blocking work (file reads, audio files, hashing) | `await Task.detached { … }.value`, off the main actor |

```swift
@MainActor
@Observable
final class DictationController {
    …
}

let samples = try await Task.detached { try AudioFile.samples(from: url) }.value
```

Rules:

- Never block the main actor with file I/O, audio processing, large text work or a wait on another app.
- Use `Task { }` and `async`/`await`. Use `DispatchQueue` only for timers and watchdogs that must fire
  even while an actor is busy, and for AppKit callbacks that need a hop to the main thread.
- A long-running `Task` is stored so it can be cancelled, and checks `Task.isCancelled` in its loop.
- Capture `[weak self]` in long-lived closures and tasks owned by `self`.
- `@unchecked Sendable` is allowed only on a class whose mutable state is guarded by a lock, with a
  comment that names the lock.
- `nonisolated(unsafe)` is allowed only for a value set once before any concurrent use, or guarded by a
  lock, with a comment that says which.
- `@ObservationIgnored` on stored properties that views must not track (handlers, tasks, caches).

## Errors

- Throw typed errors. A failure the user can see is an `enum …: LocalizedError` whose `errorDescription`
  is a full sentence for the user:

  ```swift
  public enum LanguageModelError: LocalizedError, Equatable {
      case workerStopped
      …
      public var errorDescription: String? {
          switch self {
          case .workerStopped: "The language model stopped unexpectedly. Try again."
          …
          }
      }
  }
  ```

- Say what happened and what to do next. Do not show codes, stack traces or library names.
- Report a failure in the Library window with `app.report(error, doing: "export it")`, which shows
  "Could not export it: …". Outside the window, use `Toast.show(_:)`.
- Use `try?` only where failure is harmless and expected (a missing optional file, a best-effort clean-up).
  If it is not obvious why, add a comment.
- Use `try!` only for a regular expression built from a constant pattern (see Regular expressions).
- No `fatalError` in app paths. Use it only for code that cannot be reached by design.
- A secondary control that cannot act right now is disabled, with an accessibility hint that says why. Do
  not let it be pressed and then show an error.

## Logging

All logging goes through `Log.write(area, message)` in `App/Sources/Services/Log.swift`. It appends one
line to `~/Library/Logs/Chirp/chirp.log` (or the file in `CHIRP_LOG`) from any thread.

```swift
Log.write("insert", "pasted \(text.count) characters into \(front)")
Log.write("models", String(format: "speech model probe: %.2f s", seconds))
```

- `area` is one lowercase word for the part of Chirp: `speak`, `record`, `notes`, `write`, `read`,
  `summary`, `models`, `links`, `jobs`, `insert`, `mic`, `permissions`, `features`, `shortcuts`,
  `settings`, `perch`, `notice`. Reuse one of these before adding a new one.
- Log sizes, counts, timings, states and outcomes. **Never log what the user said, typed, selected, read
  or recorded**, and never log file contents, URLs the user opened, names of people or calendar events.
- `ChirpCore` and `ChirpML` do not log directly. They hand short notes to a closure the app sets
  (`ModelHelper.log`, `transcriber.onNote`, `language.onNote`) and the app writes them with `Log.write`.
- No `print`, `NSLog` or `os.Logger`.

## Settings and feature switches

There are two places to save a preference. Pick by what it belongs to.

| Store | Use for | How |
|---|---|---|
| The database `setting` table | What belongs with the user's library and language: the writing profile, what audio to keep, reading voice and speed, onboarding done | `try engine.setting("readSpeed", as: Double.self)` and `try engine.setSetting("readSpeed", value)` |
| `UserDefaults` | Window, device and display choices: the perch's place, the sidebar, the microphone, appearance, the Dock icon | A `static let …Key` on the owning type, read in views with `@AppStorage(Type.key)` |

```swift
enum ReadingChoices {
    static let marksKey = "readMarks"
}

@AppStorage(ReadingChoices.marksKey) private var marks = true
```

- Define each key once, as a constant on the type that owns it. Do not repeat a key as a string literal.
- Every preference has a default that works without it being saved. Read with `object(forKey:) as? T ?? default`
  when the default is not `false`/`0`.
- Reading a saved value must survive older shapes. Decode field by field with defaults, as `WritingProfile`
  does, so a new field never resets the user's other choices.
- `UserDefaults` keys that only a test copy sets are not allowed in shipping code.

Feature switches:

- The six features are `Feature` in `ChirpCore/Engine/Features.swift`. What follows from the switches
  (which models are needed, which pages show, what a dropped file offers) is pure logic in `FeatureSet`,
  tested in `FeaturesTests`.
- `Features.shared` in the app saves the switches (`feature.<name>` in `UserDefaults`) and tells every part
  of the app when they change.
- In a view, `Features.on(.read)` or `.shown(with: .read)`. A switched-off feature leaves no button, page,
  shortcut, background work or loaded model behind.
- A controller that does background work registers `Features.shared.whenChanged { old, new in … }` and
  stops cleanly when its feature goes off. It reports busy work with `Features.shared.probe(_:_:)`.

## SwiftUI and AppKit

State:

- Controllers are created once in `ChirpApp.init` and injected with `.environment(controller)`. Views read
  them with `@Environment(DictationController.self) private var dictation`.
- Local view state is `@State private var`. Pass child data as `let` properties, and actions as closures.
- Do not use `ObservableObject`, `@Published`, `@StateObject` or `@EnvironmentObject`.
- Code that is not a view reaches shared objects through the controller it was given. Avoid new singletons
  and new `static var` hand-offs; the existing `AppDelegate.app` and `.shared` instances are not a pattern to copy.

Views:

- Build pages from the shared components in `App/Sources/Design/Theme.swift`: `Page`, `PageHeader`,
  `SectionHeading`, `ItemRow`, `IconButton`, `ActButton`, `Card`, `EmptyLine`, `ProgressBar`.
- Colours are the named tokens (`Color.ink`, `.paper`, `.card`, `.float`, `.quiet`, `.amber`, `.spelling`,
  `.grammar`, `.style`, `.caution`). Never a system colour or a one-off `Color(red:green:blue:)`.
  See [DESIGN.md](DESIGN.md#4-colour).
- Type sizes come from the `Font` tokens (`.pageTitle`, `.detailTitle`, `.sectionTitle`, `.reading`,
  `.rowMeta`). If a new size repeats, add a token instead of another `.system(size:)`.
- Spacing and widths come from `PageLayout` where it has a value.
- Every icon-only control has an `accessibilityLabel`. Decorative images are `accessibilityHidden(true)`.
- Elements that tests look for have an `accessibilityIdentifier` of the form `area.name` (`sidebar.home`).

AppKit:

- Floating surfaces over other apps are `NSPanel` subclasses that do not take focus unless a text field in
  them is clicked (`PerchPanel`, `FloatingPanel`). Host SwiftUI in them.
- Wrap AppKit views with `NSViewRepresentable` and keep the coordinator small.
- Talking to other apps (Accessibility, pasting, key events) lives in `Services` and in the writing
  controllers, never in views. Calls to another app are time-limited so a slow app cannot freeze Chirp.

## Regular expressions and text helpers

- A fixed pattern is a `private static let` built once, from a raw string literal:

  ```swift
  private static let entity = try! NSRegularExpression(pattern: #"&(#x?[0-9a-fA-F]+|[a-zA-Z]+);"#)
  ```

- A pattern built at run time goes through `Patterns.regex(_:options:)`, which caches it and returns nil for
  an invalid pattern. Never build an `NSRegularExpression` inside a loop.
- Use `range(of:options: .regularExpression)` only for one-off checks outside hot paths.
- Use `NSRegularExpression.replacing(in:with:)` and `rewriting(in:_:)` from `RegexSupport.swift` instead of
  writing range arithmetic again.
- Before writing a small text helper (word count, title from text, duration as "2 h 31 min", file-safe
  name), search `ChirpCore/Text` and `DocumentRows` for one that exists. Add shared helpers there.

## User-facing text

- Plain, short sentences. Say what happened or what will happen.
- Sentence case for buttons, titles and menu items: "Save as a snippet…", "Transcribe again".
- No jargon: say "speech model", "reading voice", "language model", not engine names, sizes in parameters,
  or file formats the user did not choose.
- No exclamation marks, jokes or filler. No "Oops", "Uh-oh", "Awesome".
- Errors follow "Could not … : reason" or "The … stopped unexpectedly. Try again."
- Name what deleting removes: "The notes, transcript and recording are removed from this Mac."
- Chirp works on the user's own words. It never writes content for the user. The language model only
  checks, shortens, rephrases or summarizes text the user supplied.

## Icons

- Use Chirp's own icon set in `App/Resources/Assets.xcassets/Icons`: `Image("chirp.copy")`. Symbols are
  named `chirp.<lowerCamelName>`.
- Never use SF Symbols (`Image(systemName:)`, `systemImage:`, `NSImage(systemSymbolName:)`).
- Toolbar labels use `Image.toolbarIcon("chirp.search")`. SwiftUI draws a custom symbol blank in a window
  toolbar label, so the toolbar needs an image drawn at a set size.
- A new icon is a new `chirp.*.symbolset` in the same style as the set. Do not mix in other icon families.

## Comments

- Every type and every non-obvious member has a `///` doc comment.
- Explain why: the reason, the limit, what breaks if it is changed. Do not restate what the code says.
- Comments must stand on their own. A reader with only this file must understand them.
- Never cite internal ids, ticket or test log numbers, design board names, dates of decisions, people,
  or other projects and apps. If a design follows an outside project, say so in the pull request.
- Write in plain present tense. Do not keep history ("used to", "was changed on") in comments; that is
  what git is for.
- Mark test-only paths clearly at the point they branch (`// A test copy only: …`).

```swift
/// Remembers how far a document has been read, and changes nothing else about it. Saving the whole item
/// from a copy held while reading would put back a title or summary changed elsewhere meanwhile.
public func setPosition(id: Int64, position: Int) throws { … }
```

## Tests

- Unit tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), in
  `Packages/ChirpCore/Tests/ChirpCoreTests`. Do not add new XCTest cases.
- One file per subject, named `<Subject>Tests.swift`, with `@Suite struct <Subject>Tests`.
- Test names say the behaviour as a phrase: `settingThePlaceLeavesTheRestOfTheItemAlone()`.
- Use an in-memory store: `Library(store: try ChirpStore())`. A migration test opens a temporary file at an
  earlier step with `ChirpStore(url:upTo:)` (see [DATA-MODEL.md](DATA-MODEL.md)).
- Read fixtures from `Fixtures/` through `#filePath`, and fail if the file is missing.
- Test data is made up. No real names, addresses, emails or text copied from real people or sites.
- Every change to `ChirpCore` comes with a test. Logic in the app that can be tested without a window
  moves to `ChirpCore` so it can be.
- A behaviour that needs the running app gets an end-to-end check in `Scripts/e2e.sh`. See [TESTING.md](TESTING.md).

## Performance and memory

Chirp must run well on the smallest Apple Silicon Macs, next to the apps the user is working in.

- **All model work runs in a helper process.** The helper is the app's own executable started again with a
  flag. The app process loads no model.

  | Helper | Flag | Runs |
  |---|---|---|
  | `SpeechWorker` | `--transcribe-worker` | speech to text |
  | `LanguageWorker` | `--language-worker` | the language model, the search model, the sentence checker |
  | `VoiceWorker` (`VoiceEngine`) | `--voice-worker` | the reading voice |
  | `ListenWorker` (`ListenEngine`) | `--listen-worker voice-detection` / `speakers` | voice detection, speaker labelling |

- A new model gets its own helper built on `ModelHelper` from the start.
- **One heavy model at a time.** `ModelCenter` decides what is loaded. Ask it with `ensure(_:)`, mark use
  with `beginUse`/`endUse`, and let it unload. Never keep a second large model loaded "for speed".
- Unload a model when nothing needs it: when its features are off, and after it sits idle.
- Split long work (long audio, long documents) into pieces so memory stays flat.
- Do not hold whole recordings or documents in memory when a file and an offset will do.
- Long work the user waits for while Chirp's window is hidden holds a `FullSpeed` activity, so macOS does
  not slow the app down.
- Poll other apps with backoff (`PollBackoff`) and leave a slow app alone for a while (`SlowAppGuard`).

## Debug links and test hooks

- `chirp://debug/<command>` links exist for automated checks. Register them with
  `LinkHandler.commands["name"]` and report state with `LinkHandler.stateProviders["name"]`.
- They work only when the app was started with `--debug-hooks`. Without it, shipping behaviour must be
  identical: a hook may never change what a normal launch does.
- Hooks are for driving and checking the app. Do not add switches for trying one approach against another,
  measuring experiments or loading other models. Do that on a branch.

## Never do this

- Load or run a model in the app process, or import MLX, FluidAudio or TranscribeCpp in `App`.
- Keep two heavy models loaded at once.
- Send anything off the Mac, or add analytics, crash reporting or network calls other than model and tool
  downloads, links the user asked to import, and update checks.
- Write content for the user, or call the language model with text the user did not supply.
- Log or store what the user said, typed, selected or read, beyond what the feature saves on purpose.
- Use SF Symbols, system colours or one-off colours.
- Edit a database migration that has shipped, or rename a stored enum case.
- Block the main actor with file, audio or model work.
- Use `ObservableObject`, `print`, `NSLog` or `os.Logger`.
- Add test-only or experiment switches to shipping code paths.
- Put real personal data in code, tests, fixtures or scripts. No absolute paths to anyone's home folder.
- Cite internal ids, tickets, dates or other projects in comments.

## Before you open a pull request

- [ ] `cd Packages/ChirpCore && swift test` passes.
- [ ] The app builds in Release (see [DEVELOPMENT.md](DEVELOPMENT.md)).
- [ ] New logic in `ChirpCore` has tests; a new user flow has an end-to-end check or a note on how it was tried.
- [ ] No model code in the app process; heavy work is off the main actor.
- [ ] New text is plain and short; new icons come from the `chirp.*` set; colours are tokens.
- [ ] No user content in logs; no personal data or machine paths anywhere.
- [ ] Comments explain why and cite no ids, dates, people or other projects.
- [ ] A schema change is a new migration with a test (see [DATA-MODEL.md](DATA-MODEL.md)).
