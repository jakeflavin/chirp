# Architecture

How Chirp is put together, and the rules for extending it. Read this before adding a feature, a model
or a helper process. Related docs: [MODELS.md](MODELS.md), [PRIVACY.md](PRIVACY.md), [FEATURES.md](FEATURES.md).

Chirp is a native macOS app (macOS 26+, Apple silicon only) written in Swift, SwiftUI and AppKit. Every
model runs on the Mac. The Xcode project is generated from `project.yml` with XcodeGen.

## Rules (read these first)

1. **The app process loads no model.** All model work runs in a helper process: the app's own
   executable started again with a flag. New model work goes into a helper from the start.
2. **Dependencies point one way:** `App` → `ChirpML` → `ChirpCore`. `ChirpCore` imports nothing but
   Foundation and GRDB. Never import `ChirpML` or the app from `ChirpCore`.
3. **New helpers are built on `ModelHelper`** (`Packages/ChirpML/Sources/ChirpML/ModelHelper.swift`).
   The speech worker and the language helper have their own launchers for reasons given below; do not
   copy them.
4. **Every model goes through `ModelCenter`** (`App/Sources/Services/ModelCenter.swift`) for download
   state, loading, unloading and memory.
5. **Every feature checks its switch** (`Features`). A switched-off feature does nothing: no UI, no
   shortcuts, no background work, no model.
6. **Every network call is listed in [PRIVACY.md](PRIVACY.md).** A pull request that adds one without
   updating that file is incomplete.
7. **Chirp transforms the user's own text.** Language model prompts (`ChirpCore/Engine/Prompts.swift`)
   fix, rephrase, shorten, join or summarize what the user gave. They never write new content.

## Module map

```
┌──────────────────────────────────────────────────────────────────────────┐
│ App (target "Chirp")  App/Sources/*                                        │
│ SwiftUI + AppKit. Windows, perch, menu bar, controllers, permissions,      │
│ ModelCenter, Features, links. Depends on KeyboardShortcuts.                │
└───────────────┬───────────────────────────────┬──────────────────────────┘
                │                               │ (GrammarChecker only)
                ▼                               ▼
┌───────────────────────────────┐   ┌─────────────────────────────────────┐
│ ChirpML  Packages/ChirpML     │   │ ChirpHarper (C module)              │
│ App-side model clients and    │   │ Rust/include + Rust/lib             │
│ the helper processes' code.   │   │ libchirp_harper.a, a static library │
│ MLX, FluidAudio, Hugging Face │   │ built from Rust/chirp-harper over    │
│ hub, swift-transformers.      │   │ harper-core. Runs in the app process.│
└───────┬───────────────┬───────┘   └─────────────────────────────────────┘
        │               │
        ▼               ▼
┌───────────────┐ ┌──────────────────────────────────────────────────────┐
│ TranscribeCpp │ │ ChirpCore  Packages/ChirpCore                         │
│ Swift bindings│ │ Pure logic and storage. No UI, no models. GRDB only.  │
│ + prebuilt    │ │ `swift test` runs here in seconds.                    │
│ xcframework   │ └──────────────────────────────────────────────────────┘
└───────────────┘          ▲  App and ChirpML both import ChirpCore
```

| Module | Path | Owns | May import |
|---|---|---|---|
| App | `App/Sources` | Every window and panel, feature controllers, permissions, `ModelCenter`, `Features`, `chirp://` links, logging | ChirpCore, ChirpML, ChirpHarper, KeyboardShortcuts, Apple frameworks |
| ChirpML | `Packages/ChirpML` | The app-side clients of each model (`Transcriber`, `LanguageModel`, `Embedder`, `FactChecker`, `Voice`, `SpeakerLabeler`), the helper processes (`SpeechWorker`, `LanguageWorker`, `VoiceWorker`, `ListenWorker`), and the helper launchers | ChirpCore, TranscribeCpp, FluidAudio, MLX / mlx-swift-lm, swift-huggingface, swift-transformers |
| TranscribeCpp | `Packages/TranscribeCpp` | Swift bindings for transcribe.cpp, copied unchanged from its `bindings/swift` at tag v0.4.2, plus the release's prebuilt xcframework (downloaded by SwiftPM, pinned by checksum) | Accelerate, Metal |
| ChirpCore | `Packages/ChirpCore` | The SQLite library (`Store/`), text rules (`Text/`), the reading pipeline (`Reading/`), meetings logic (`Meetings/`), summary planning and checks (`Engine/Summary.swift`), prompts, feature switch logic (`Engine/Features.swift`), Home lines | Foundation, GRDB |
| chirp-harper | `Rust/chirp-harper` | A small C interface over harper-core: `chirp_checker_new`, `chirp_checker_lint`, `chirp_checker_free`, `chirp_string_free` (`Rust/include/chirp_harper.h`). Catches Rust panics so a fault cannot end the app | harper-core, serde_json |

Build notes:

- `Rust/lib/` is not in git. Run `scripts/build-harper.sh` (needs Rust) before the first Xcode build.
  The app links it with `-L$(PROJECT_DIR)/Rust/lib -lchirp_harper`.
- `ChirpCore` builds and tests with plain `swift test`. `ChirpML` needs `xcodebuild` (MLX needs the Metal toolchain).
- `CHIRP_CHANNEL: Beta` in `project.yml` sets the `BETA` compilation condition and the Beta icon.
  Empty it for a build with no Beta marks.

Harper is the one third-party engine that runs inside the app process. It is a rule-based checker,
not a model, and its calls are wrapped so a panic returns an error instead of ending the app.

### Names to know about

- `ChirpCore.PersonalLanguage` (`Engine/PersonalLanguage.swift`): the user's dictionary, snippets, style
  and settings stored in SQLite. The app calls it `app.engine`.
- `ChirpML.LanguageEngine` (internal actor, `LanguageEngine.swift`): the MLX language model inside the
  language helper.
- `ChirpCore/Engine/Features.swift` holds the pure logic (`Feature`, `FeatureSet`, what each feature needs);
  `App/Sources/Shell/FeatureSwitches.swift` holds the observable switch store that applies it.

## App feature folders

| Folder | What it does | Main types |
|---|---|---|
| `Shell/` | App entry, the Library window and its pages, Home, Settings, menu bar popover, feature switches, shortcuts layout, `chirp://` links | `Main`, `ChirpApp`, `AppDelegate`, `AppModel`, `LibraryWindow`, `HomePage`, `SettingsPage`, `MenuBarModel`, `Features`, `ShortcutLayout`, `LinkHandler` |
| `Perch/` | The perch: the small glass bar at the bottom of the screen that is Chirp's presence while the user works. Drops, placement, customisation, the recording panel, the menu bar icon | `PerchController`, `PerchView`, `FileDragWatcher`, `RecordingPanel`, `MenuBarIcon` |
| `Speak/` | Dictation from key press to inserted text, the Dictations page row and Settings › Dictation | `DictationController`, `HoldKeyMonitor`, `SpeakOptions` |
| `Record/` | Meetings and voice notes: capture, live transcript, recovery after a crash, notes writing, call detection, file and link import, the job queue | `MeetingRecorder`, `MeetingDetector`, `LinkImporter`, `Jobs`, `RecordPage` |
| `Write/` | Writing checks in other apps (underlines, cards, the sentence bird), the rewrite panel (Proofread, Shorten, Rephrase, Write out), Chirp's own checked editor | `UnderlineController`, `GrammarChecker`, `WritingAssistant`, `SelectionPanelController`, `SentenceFixer`, `CheckedTextEditor` |
| `Read/` | Read aloud (selection, documents, files, web pages), summaries, the document view, import of files and web pages, highlighting in other apps | `ReadController`, `DocumentImporter`, `DocumentDetail`, `ReadHighlighter`, `SentencePlayer`, `PageSaver` |
| `Notes/` | Typed notes in the perch and on the Notes page, with the same editor | `NoteController`, `NoteEditor`, `NoteDetail`, `PerchNoteContent` |
| `Remember/` | Search (by words and by meaning), Dictionary, Snippets, Writing style pages | `SearchController`, `SearchView`, `DictionaryView`, `SnippetsView` |
| `Onboarding/` | First-run window: a tour that also sets things up | `FirstRunWindow`, `OnboardingView`, `OnboardingStep` |
| `Services/` | Shared services: models, permissions, audio capture, system audio tap, calendar, text insertion, screen reading, log, reset | `ModelCenter`, `Permissions`, `AudioRecorder`, `SystemAudioTap`, `CalendarReader`, `TextInserter`, `ScreenReader`, `Log`, `DangerZone` |
| `Design/` | Colours, glass surfaces, the bird, Markdown rendering, Beta marks | `Theme`, `GlassSurface`, `Bird`, `MarkdownText` |

See [FEATURES.md](FEATURES.md) for each feature's flow through these files.

## Process model

```
                       Chirp.app/Contents/MacOS/Chirp
                                   │
     ┌─────────────────────────────┼──────────────────────────────────────┐
     │ app process (no flag)       │                                      │
     │ UI, controllers, ModelCenter, Harper, Apple Vision                 │
     └──┬────────────┬─────────────┬──────────────┬───────────────┬───────┘
        │ pipes      │ pipes       │ pipes        │ pipes         │ pipes
        ▼            ▼             ▼              ▼               ▼
  --transcribe-  --language-   --voice-     --listen-worker  --listen-worker
    worker         worker        worker      voice-detection     speakers
  Parakeet       Qwen (+LoRA)   Kokoro       Silero VAD        pyannote
  (transcribe.   bge-small      (FluidAudio) (FluidAudio)      (FluidAudio)
   cpp, GPU/CPU) MiniCheck
                 (MLX)
  SpeechSupervisor LanguageSupervisor  ───── ModelHelper (one each) ─────
```

`Main.main()` in `App/Sources/Shell/ChirpApp.swift` checks the first argument before the app starts.
With a helper flag the process runs that helper and never becomes an app.

| Helper | Flag | Code (helper side / app side) | Runs | Launcher |
|---|---|---|---|---|
| Speech worker | `--transcribe-worker` | `SpeechWorker` / `SpeechSupervisor` in `SpeechWorker.swift`, used by `Transcriber` | Parakeet TDT v2 through transcribe.cpp | `SpeechSupervisor` |
| Language helper | `--language-worker` | `LanguageWorker` / `LanguageSupervisor` in `LanguageWorker.swift`, used by `LanguageModel`, `Embedder`, `FactChecker` | The language model (and summary model + adapter), the search model, the sentence checker (all MLX) | `LanguageSupervisor` |
| Voice helper | `--voice-worker` | `VoiceWorker` + `VoiceEngine` in `VoiceEngine.swift` / `Voice` in `Voice.swift` | Kokoro through FluidAudio | `ModelHelper` |
| Listen helper, voice detection | `--listen-worker voice-detection` | `ListenWorker` + `VoiceDetectionEngine` in `ListenEngine.swift` / owned by `Transcriber` | Silero VAD through FluidAudio, processor only | `ModelHelper` |
| Listen helper, speakers | `--listen-worker speakers` | `ListenWorker` + `SpeakerEngine` in `ListenEngine.swift` / `SpeakerLabeler` | pyannote speaker labelling through FluidAudio, processor only | `ModelHelper` |

Why separate processes:

- **A crash cannot take the app down.** A GPU fault, an assert in native code, an MLX fatal error or
  macOS ending a process for memory ends only that helper. The next request starts a fresh one.
- **Ending a helper gives all of its memory back.** Unloading a model means ending its process. Model
  libraries do not reliably free memory in place; process exit does.
- **Helpers do not block each other.** Voice detection is not in the speech worker on purpose: the
  speech worker treats a lost worker as a GPU failure and moves speech to the processor, and a fault
  in voice detection must not do that. Speaker labelling is a second copy of the listen helper so it
  can be ended while voice detection carries on.

Common behaviour of every helper:

- Requests and replies are framed messages on the helper's standard input and output. The helper
  points its own `stdout` at `stderr` so library prints cannot corrupt the pipe.
- The helper exits when the app closes its input. It also polls `getppid()` every 2 seconds and exits
  if the app has gone (so a killed app does not leave a model in memory).
- The app sets `F_SETNOSIGPIPE` on the write end so writing to a dead helper fails instead of
  raising `SIGPIPE` in the app.
- A silent helper is killed after a time limit; a cancelled request is asked to stop, then the helper
  is killed after a grace period.
- No request is retried silently, except where the speech worker's GPU fallback says otherwise.
- `RestartLimit` (`ChirpCore/Engine/RestartLimit.swift`) stops a helper that keeps dying from being
  started over and over: after repeated deaths it is left alone for a minute.

### The three launchers

There are three launchers because the first two came before the shared one. They differ in real ways.

**`ModelHelper`** (`ChirpML/ModelHelper.swift`). Build new helpers on this one.

- Frame: kind byte, request id, op name, JSON, and a raw binary blob (17-byte header). Every request
  carries an id and its reply carries the same id, so several requests can be in flight at once.
- Helper side is `HelperWorker.serve([op: handler])`: a dictionary of async handlers. Each request
  runs in its own task; a `cancel` frame cancels that task.
- Replies: `progress`, `reply`, `failed`, `cancelled`. A `failed` reply is a refusal, not a death.
- Per-request silence timer, reset by each `progress` frame.
- Audio is written to the pipe straight from the `[Float]` array, not copied.
- Test faults: `kill:<op>`, `kill-after:<op>:<ms>`, `hang:<op>` (`HelperFault`), set over the pipe.
- Registers itself in `ModelHelper.all`, so the `helpers` debug state and `helper-fault` link work for
  every helper with no extra code.

**`SpeechSupervisor`** (in `ChirpML/SpeechWorker.swift`). Specific to speech; do not reuse.

- Synchronous and serial: one `NSLock` held for a whole load or transcription. One request at a time.
- Frame: kind byte and a 4-byte length; two requests (`load`, `run`) and four replies, including
  `backendFailed`.
- GPU fallback logic: a GPU that fails to load the model retries on the processor; a crash or hang on
  the GPU retries once on the processor; a first backend error on the GPU retries in a fresh GPU
  worker; a second moves to the processor. `retryGPU()` clears the flag when the user changes the
  setting.
- Run time limit is ten times the audio length (at least 60 s on the GPU, 300 s on the processor);
  load limit is 180 s.
- `cancelRun()` kills the worker mid-transcription; the model still counts as loaded and the next
  request starts a fresh worker.
- Test faults come from the `CHIRP_WORKER_FAULT` environment variable, not the pipe.

**`LanguageSupervisor`** (in `ChirpML/LanguageWorker.swift`). One shared instance for all MLX work.

- Frame: kind byte and a 4-byte length. Replies are split into two lanes by kind number: the language
  model's lane, and the search lane (search model and sentence checker, kinds 110 and up). Each lane has
  its own `TurnGate` (`runGate`, `embedGate`), so a search typed during a summary does not wait for it.
- No request id: one request at a time per lane.
- Streams generated text as `partial` frames; supports batched runs (`runBatch`, see
  `BatchedGeneration.swift`) and a memory query.
- The search model's idle timer (`Embedder.idleSeconds`, 240 s) can end the helper when it holds only
  the search model (`endIfOnlySearch`).
- Test faults travel inside the run request (`LanguageRunRequest.fault`).

It differs because two language model runs at once crashed MLX, so runs must take turns, and because
the three MLX models share one process, one MLX runtime and one capped buffer pool
(`MLX.Memory.cacheLimit` is 64 MB). The sentence checker shares the search lane; the two are never
used at once. A new MLX model should join this helper, not get a helper of its own.

## ModelCenter

`App/Sources/Services/ModelCenter.swift`, `@MainActor @Observable`, one instance made in `ChirpApp.init`
and shared through the environment and `AppDelegate.models`.

What it does:

- **State per model** (`ModelKind`: `transcription`, `language`, `voice`, `speakers`, `search`):
  `notDownloaded`, `downloading(fraction)`, `onDisk`, `loading`, `loaded`, `failed(reason)`. Screens
  read `models.state(kind)`.
- **`ensure(kind)`** downloads if needed and loads. Callers that arrive while a load is in progress
  wait for it (`waitWhileBusy`, up to 330 s; an hour while downloading). A model already on disk gets
  300 s to load (`loadLimit`), then fails as "took too long".
- **Registration.** The speech and language models are built in. Features that own other models
  register them: `ReadController` registers `.voice`, `MeetingRecorder` registers `.speakers`,
  `SearchController` registers `.search`, each with `onDisk`, `load` and `unload` closures.
- **One heavy model at a time** on Macs under 12 GB (`lowMemory`, from `MacMemory` in `ChirpCore/Engine/ModelChoice.swift`). `heavy` is `[.language, .voice]`.
  Loading one heavy model first unloads the other, waiting up to 30 s (`unloadWait`); if it cannot be
  put away the caller gets "busy". A model in use (`beginUse`/`endUse`) is never unloaded to make room.
- **Idle unloading.** On small Macs a heavy model unused for 4 minutes (voice: 30 minutes) is unloaded.
  The speech model has its own timer (`watchSpeechIdle`, default 5 minutes, Settings › Dictation),
  and is held while a recording runs (`Transcriber.hold()`/`release()`). The search model's helper
  has its own 240 s idle check inside `Embedder`.
- **Language model size.** `LanguageModelSize` (`ChirpCore/Engine/ModelChoice.swift`): small (2B),
  medium (4B), large (9B). Automatic picks medium at 16 GB and up, else small; large is only ever a
  user choice. If the chosen size fails to load, `ModelCenter` steps down a size for the session.
- **Summary model.** When the general model is the 2B, summaries load a separate small model with a
  LoRA adapter in its place (`summaryModel`, `ensureSummaryModel()`), and the general model comes back
  for the next job. If it will not load, summaries use the general model until the next launch.
- **Sentence checker** location (`summaryCheckerDirectory`); see [MODELS.md](MODELS.md).

Memory guidance for contributors: assume the smallest supported Mac. Never keep a model loaded "just
in case"; register it, let `ModelCenter` load it on demand, and use `beginUse`/`endUse` around a job
that calls it many times.

## App lifecycle

```
launch ─► Main.main(): helper flag? ─yes─► run helper, never return
            │ no
            ▼
          ChirpApp.init(): Features.shared → AppModel (opens SQLite) → ModelCenter
            → DictationController → MeetingRecorder → MeetingDetector → WritingAssistant
            → SelectionPanelController → UnderlineController → ReadController
            → PerchController → MenuBarModel → SearchController
            → features.applyAtLaunch() → ShortcutLayout.start()
            ▼
          applicationDidFinishLaunching: speech idle watcher, appearance, Dock icon,
            FirstRunWindow follows app.showOnboarding
            ▼
          No window at launch. The perch and the menu bar item are the app.
```

- **Launch.** The Library window (`Window("Chirp", id: "main")`) uses `.defaultLaunchBehavior(.suppressed)`,
  so nothing opens at launch except the perch, the menu bar item, and onboarding on first run.
  Closing the window does not quit (`applicationShouldTerminateAfterLastWindowClosed` is false).
- **Onboarding.** `AppModel.showOnboarding` is true until the `onboardingDone` setting is saved.
  `FirstRunWindow` shows `OnboardingView` in its own small window. Its steps are filtered by which
  features are on. It downloads no model until the user presses a Download button (the speech model's
  on the Dictation step, each model's or "Download all" on the Models step). Leaving it adds one
  sample document (`FirstData`) and opens the Library on Home. It can be reopened from Settings ›
  General; that reopening resets nothing.
- **Menu bar.** `MenuBarModel` and `MenuBarPopover` (`Shell/MenuBarPopover.swift`) use an
  `NSStatusItem` and a custom non-activating panel, not `MenuBarExtra`, so the popover can be opened
  and closed by code and does not take focus from the app being used.
- **Perch.** `PerchController` owns a non-activating `PerchPanel` that floats over other apps. It
  shows the actions at rest and grows to show whatever Chirp is doing (dictation, a recording, reading,
  a summary, suggestions, the rewrite panel, a note, a dropped file).
- **Library window.** `LibraryWindow` hosts Home, All, Meetings, Notes, Dictations, Documents,
  Dictionary, Snippets, Writing style, folders and Settings (Settings is a page of this window, not a
  window of its own). Pages for switched-off features leave the sidebar (`FeatureSet.shows`).
- **Dock icon** is optional (`DockPresence`). With it off, the menu bar item is forced on.
- **Shortcuts.** Global shortcuts use the KeyboardShortcuts package. Defaults put everything under the
  right hand: holding right Option alone dictates; with right Option held, N records a voice note,
  M a meeting, L reads aloud, U summarizes, I opens the rewrite panel, K rephrases, O opens the Library,
  P pastes the last dictation. ⌥Space is hands-free dictation and ⌥Tab fixes the current sentence when
  a fix is on offer. Option-letter shortcuts are registered only while the right Option key is down
  (`ShortcutLayout`), so left Option still types symbols.
- **Quit.** `applicationWillTerminate` stops the speech worker, the voice-detection helper and the
  language helper at once. The voice helper and the speaker-labelling helper notice the app has gone
  within 2 seconds and exit.
- **Recovery.** A recording that was running when Chirp quit or crashed is journalled to disk
  (`RecordingJournal`) and finished on the next launch (`MeetingRecorder.recover()`).

## Feature switches

Six switches in Settings › General › Features: Dictate, Meetings, Notes, Read aloud, Writing checks,
Summarize (`ChirpCore.Feature`). All are on unless switched off. Each is saved in `UserDefaults` as
`feature.<name>`.

- `ChirpCore/Engine/Features.swift` decides what follows from a set of switches: which models are
  needed (`needs`), which Library pages show (`shows`), what a dropped file offers (`dropOffers`).
- `App/Sources/Shell/FeatureSwitches.swift` stores the switches and applies a change: runs every registered
  `whenChanged` handler (each feature stops its own work cleanly), unregisters that feature's
  shortcuts, and unloads models no feature still needs once whatever is using them has finished.
- In views, use `.shown(with: .feature)` or `Features.on(.feature)`. Long work checks the switch between
  steps and throws `FeatureSwitchedOff`.

When you add a feature: add the case to `Feature`, say which models it needs in `needs`, which pages it
fills in `shows`, add its shortcuts to `Features.shortcuts`, and register a `whenChanged` handler that
stops its work.

## Data and settings

- The library is one SQLite database through GRDB (`ChirpStore`, `ChirpCore/Store/`), with migrations
  in `ChirpStore.migrator`. Search by words uses FTS5 tables (`itemFTS`, `transcriptFTS`,
  `attachmentFTS`); search by meaning stores vectors in the `chunk` table.
- Settings are split: some in `UserDefaults` (feature switches, model choices, Dock and menu bar,
  test switches), others in the database through `app.engine.setting(...)` (dictation, reading,
  recording options, `onboardingDone`). Check both when looking for a setting.
- File locations are listed in [PRIVACY.md](PRIVACY.md#where-data-lives).

## Testing hooks

- `--debug-hooks` enables `chirp://debug/<command>?…` links (`LinkHandler`, `Shell/DebugHooks.swift`).
  Features register commands in `LinkHandler.commands` and state in `LinkHandler.stateProviders`;
  `chirp://debug/state?path=<file>` writes all of it as JSON. Without the flag only `chirp://show/…`
  works.
- Other launch flags: `--ui-testing` (in-memory library), `--data-dir <folder>` (a separate library),
  `--skip-onboarding`, `--no-window`, `--no-global-shortcuts`.
- `scripts/e2e.sh` drives a test copy end to end through these links.
