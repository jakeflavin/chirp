# Features

What each feature does for the user and how it runs through the code. Paths are under `App/Sources`
unless they start with `Packages/`. For the module layout and helper processes see
[ARCHITECTURE.md](ARCHITECTURE.md); for models see [MODELS.md](MODELS.md); for network use and
permissions see [PRIVACY.md](PRIVACY.md).

The six switchable features (Settings › General › Features) are Dictate, Meetings, Notes, Read aloud,
Writing checks and Summarize. In this file "Record" covers Meetings and Notes. Debug hooks are
`chirp://debug/<name>` links that work only when Chirp is launched with `--debug-hooks`.

Default shortcuts: hold right Option alone to dictate; with right Option held, N voice note, M meeting,
L read aloud, U summarize, I rewrite panel, K rephrase, O open the Library, P paste last dictation.
⌥Space is hands-free dictation. ⌥Tab fixes the sentence the cursor is in when a fix is on offer. All
can be changed in Settings › Shortcuts.

## Dictate

**What the user sees.** Hold the dictation key (right Option by default) or press ⌥Space, speak, and let
go or press again. A small overlay shows the bird on its wire while listening. The words are typed into
the app in front. Escape cancels. Each dictation is saved to Library › Dictations, where it can be
copied, edited, played back (if audio is kept) or transcribed again. ⌥P types the last dictation again.
Phrases said often are offered as snippets.

**Flow.**

1. `HoldKeyMonitor` (global `flagsChanged` monitor) or the KeyboardShortcuts handler calls
   `DictationController.keyDown` / `start(target:)` (`Speak/DictationController.swift`).
2. `AudioRecorder` (`Services/AudioRecorder.swift`) captures the microphone as 16 kHz mono and reports
   levels. `Transcriber.hold()` keeps the speech model from unloading meanwhile.
3. Long dictations are transcribed in pieces while still speaking (`startPieces`, `transcribeReadyPieces`,
   every `longDictationPieceSeconds`, default 25), cut at pauses found by voice detection.
4. `finish()` → `process(_:)`: `Transcriber.transcribe` in the speech worker, with one retry on worker
   loss (`transcribeWithRecovery`).
5. The text is cleaned **by rule, not by a model**: `DictationPipeline` (in `DictionaryCorrector.swift`) and the rules in
   `Packages/ChirpCore/Sources/ChirpCore/Text/` (`TextCleaner`, `SpokenLists`, `SpokenFormatting`,
   `TechnicalSpeech`, `DictionaryCorrector`, `LongForm`), plus snippets triggered by their spoken cue.
6. `TextInserter.insert` (`Services/TextInserter.swift`) adapts spacing and capitals to the text around
   the cursor (`Insertion.adapt`), pastes through the clipboard with ⌘V, and restores the clipboard.
7. The dictation is saved with `Library.save`; its audio goes to `Audio/` if "keep audio" is on.

**Permissions.** Microphone. Accessibility (to paste into other apps and to see the hold key in other
apps); without it the text is left on the clipboard.

**Models.** Parakeet in the speech worker; Silero voice detection in the listen helper.

**Debug hooks.** `dictate`, `key`, `hold-key`, `right-option`, `stop`, `cancel`, `transcribe`,
`mic-trial`, `editlast`.
Environment: `CHIRP_WORKER_FAULT`.

## Record: meetings and voice notes

**What the user sees.** Right Option + M starts a meeting, right Option + N a voice note (also from the
perch and menu bar). The perch shows the recording; its panel (`Perch/RecordingPanel.swift`) shows the
live transcript and lets the user type a timed note or keep a picture of the front window. When a call
app starts using the microphone, or a calendar meeting starts, Chirp offers to record. After Stop, the
recording appears in Library › Meetings or Notes. A meeting gets notes (summary, key points, decisions,
plus the user's own notes) and a transcript with speakers; a voice note is its words as clean text.
Files can be attached to a meeting.

**Flow.**

1. `MeetingRecorder.start(_:title:sourceApp:)` (`Record/MeetingRecorder.swift`). For a meeting, the
   current calendar event names it (`CalendarReader`). A `RecordingJournal`
   (`Packages/ChirpCore/.../Meetings/RecordingJournal.swift`) writes both sides' audio to disk as it
   arrives, so a crash loses nothing.
2. Two sides, each a `Channel`: the microphone ("Me", `AudioRecorder`) and, for meetings, the Mac's
   sound ("Them", `SystemAudioTap`, a Core Audio process tap). Each side is cut at pauses and transcribed
   piece by piece in the speech worker, giving the live transcript.
3. `MeetingDetector` (`Record/MeetingDetector.swift`) polls every three seconds which apps hold the
   microphone (`CallDetection`) and offers to record; when that call ends, the recording ends.
4. `stop()` → finishing steps: transcribe what is left, label speakers with `SpeakerLabeler` (if "tell
   speakers apart" is on), save the item, transcript and timed notes.
5. For a meeting, `writeNotes(for:)` queues a job in `Jobs` (`Record/Jobs.swift`) and `composeNotes`
   asks the language model for each part of the transcript, then joins the parts in code.
6. On the next launch, `recover()` finishes a recording that was cut off by a quit or crash.

**Import.** A file dropped on the perch or the Dock, opened with Chirp, or added with Add › File is
transcribed by `DictationController.transcribe(file:)` and saved under Documents. A link (Add › Link)
goes to `LinkImporter` (`Record/LinkImporter.swift`): a sound file or podcast episode is downloaded to a
temporary file; a video page is fetched with yt-dlp. Imports and notes-writing take turns in `Jobs`;
dictation and live recording never wait there.

**Permissions.** Microphone; System Audio Recording for the other side of a call; Calendars to name
meetings and offer to record; Screen Recording only when the camera button is used.

**Models.** Parakeet and Silero (transcription, cutting); pyannote (speakers, meetings only); the
language model (meeting notes only; voice notes use no language model).

**Debug hooks.** `meeting-start`, `meeting-stop`, `meeting-note`, `meeting-capture`, `meeting-notes-stop`,
`meeting-redo`, `meeting-offer`, `meeting-offer-accept`, `meeting-attach`,
`meeting-detach`, `meeting-import`, `calendar-fake`, `call-name`, `transcribe-link`, `link-ask`,
`link-kind`, `link-choose`, `link-cancel`, `link-tool`, `job-hold`, `job-cancel`, `retranscribe-kept`,
`drop`, `drop-do`, `file-drag`. Environment: `CHIRP_RECORD_TEST`, `CHIRP_LINKTOOL_BASE`,
`CHIRP_TOOLS_DIR`, `CHIRP_SYSTEM_AUDIO`; launch flags `--feed-*` feed recorded audio from files.

## Writing checks

**What the user sees.** In other apps' text fields, spelling, grammar and style problems get
underlines drawn over the app. Clicking one opens a small card (`Write/SuggestionCard.swift`) with the
fix, Add to Dictionary, dismiss, or stop this kind of suggestion. A small bird after a sentence with
problems fixes the whole sentence on click or ⌥Tab. Selecting text and pressing right Option + I opens
the rewrite panel (Proofread, Shorten, Rephrase with a formality, Write out); right Option + K rephrases
straight away. The result is shown as a change and put back in place. The same checks run in Chirp's
own note editor.

**Flow.**

1. `UnderlineController` (`Write/UnderlineController.swift`) polls the focused field of the front app
   through Accessibility a few times a second, skipping secure and sign-in fields, and reads its text
   and the screen position of each range.
2. `GrammarChecker` (`Write/GrammarChecker.swift`) runs Harper through the C interface
   (`ChirpHarper`, `Rust/chirp-harper`), off the main thread, with the user's dictionary words accepted
   and dismissed rules skipped. An optional deeper check asks the language model to proofread a
   paragraph and turns each change into a suggestion; it is on in Chirp's own editors and, by default,
   in other apps only on Macs with 16 GB or more.
3. `UnderlineOverlay` draws the underlines in a transparent window over the app (`UnderlineLook` sets
   the line styles).
4. A fix replaces the range through Accessibility or, failing that, by selecting it and pasting
   (`TextInserter`).
5. `SentenceFixer` (`Write/SentenceFixer.swift`) registers ⌥Tab only while a fix is on offer.
6. Rewrites: `SelectionPanelController` (`Write/SelectionPanel.swift`) reads the selection, and
   `WritingAssistant.rewriteChecked` (in `GrammarChecker.swift`) runs the task with the language
   model, then checks the answer by rule (`RewriteCheck` in
   `Packages/ChirpCore/.../Text/RewriteCheck.swift`). An answer that adds facts or drops the user's
   words is asked for once more, then refused.
7. The Dictionary (Library › Dictionary, `Remember/RememberPage.swift`) holds the user's words, what
   speech recognition mishears them as, and how to say them; it feeds Harper, dictation clean-up and
   read aloud.

**Permissions.** Accessibility.

**Models.** Harper (always; not a model). The language model for rewrites and the deeper check.

**Debug hooks.** `underline-seed`, `underline-apply`, `underline-card`, `underline-fixall`,
`underline-reset`, `fix-sentence`, `bird-click`, `bird-shot`, `card-shot`, `panel`, `panel-run`,
`panel-again`, `panel-close`, `panel-snippet`, `write-run`, `write-act`, `write-accept`, `write-set`,
`write-deep`, `write-fixall`, `write-caret`, `write-card`, `copy-check`.

## Read aloud

**What the user sees.** Select text in any app and press right Option + L: Chirp reads it, and where
the app can say where its text is, highlights the sentence and word being read. The perch controls
playback (pause, skip, speed). Documents in the Library (files, web pages, pasted text)
are read the same way, with the word followed on the page; a document can be saved as audio.
"Say it as" fixes how a word is pronounced. Eleven voices, in Settings › Reading.

**Flow.**

1. `ReadController.readSelection` (`Read/ReadController.swift`) gets the selection
   (`TextInserter.selectedText`, Accessibility, or ⌘C).
2. The text is cleaned for speech (`Packages/ChirpCore/.../Reading/`: `SpeechText`, `SayItAs`,
   `Citations`, `ReadMarks`) and split into sentences.
3. `Voice.speak` sends each sentence to the voice helper (`--voice-worker`, Kokoro via FluidAudio) and
   gets back samples plus phoneme durations; `WordTiming` turns those into word times.
4. `SentencePlayer` (`Read/SentencePlayer.swift`) plays one sentence while the next is made.
5. `ReadHighlighter` (`Read/ReadHighlighter.swift`) draws the sentence and word bands over the other
   app, from the same Accessibility geometry the writing checks use.
6. Documents are imported by `DocumentImporter` (`Read/DocumentImporter.swift`: PDF, EPUB, Word, RTF,
   HTML, text, web pages) and shown by `DocumentDetail` (`Read/DocumentView.swift`).

**Permissions.** Accessibility (selection and highlighting in other apps).

**Models.** Kokoro in the voice helper.

**Debug hooks.** `read-text`, `read-selection`, `read-file`, `read-web`, `read-play`, `read-pause`,
`read-stop`, `read-skip`, `read-speed`, `read-jump`, `read-page`, `read-once`,
`read-dismiss`, `read-export`, `read-brackets`, `read-citations`, `read-roundtrip`, `read-unload`,
`say-it-as`, `doc-view`, `doc-keep`, `doc-transcript`. Environment: `CHIRP_TTS_DIR`,
`CHIRP_VOICE_KEEP`.

## Summarize

**What the user sees.** Right Option + U summarizes the selection or the document in front. A document
dropped on the perch offers Summarize. A Library document has a Summarize button and shows the summary
in a panel above the text. The summary is a set of short points under headings, shown as each part is
ready, with a progress line for long documents.

**Flow.**

1. `ReadController` builds a `SummaryPlan` (`Packages/ChirpCore/.../Engine/Summary.swift`): boilerplate
   and ads removed (`Boilerplate`), the text split into parts, short sections taken as their own first
   sentences without a model.
2. `ModelCenter.ensureSummaryModel()` loads the summary model (Qwen3 0.6B with its LoRA adapter on Macs
   that use the 2B) or the general language model.
3. Parts are written in batches in one model pass (`LanguageModel.runBatch`, `BatchedGeneration.swift`).
4. Every point is checked by rule against its part (`SourceCheck` in
   `Packages/ChirpCore/.../Text/SourceWords.swift`): a point that changes a number, a
   name or a negation is replaced by the closest source sentence.
5. If the sentence checker is installed, `FactChecker` scores each point against the source in the
   language helper, and unsupported points are replaced too.
6. Sections are shown in order as they are ready (`summaryDraft`), then saved with the item.

**Permissions.** Accessibility, to read a selection in another app.

**Models.** Summary model or general language model; MiniCheck if present.

**Debug hooks.** `read-summarize`, `summarize-here`, `read-show-summary`, `summary-fold`,
`summary-seed`, `llm-fault`, `llm-worker`.

## Notes and search

**Notes.** A typed note opens in the perch (`Notes/PerchNote.swift`) and full size on Library › Notes
(`Notes/NoteDetail.swift`), with the same Markdown editor (`Notes/NoteEditor.swift`): marks are hidden
except in the paragraph being edited, and writing checks run in it. Holding right Option dictates at
the cursor. `NoteController` (`Notes/NoteController.swift`) saves as the user types and handles Copy,
Export and Share. Typed notes and voice notes are both stored as `voiceNote` items, the typed text in
the `itemNote` table. The Notes switch covers both. No language model is used.

**Search.** The search field in the Library toolbar searches everything saved. `SearchController`
(`Remember/SearchController.swift`) shows exact-word matches at once (SQLite FTS5 through `Library.search`)
and adds matches by meaning when the search model is ready (`SemanticSearch` in
`Packages/ChirpCore/.../Store/SemanticSearch.swift`). Search by meaning is off until the user presses
"Turn on search by meaning"; that downloads the search model and embeds every item's passages into the
`chunk` table. New items are embedded only when the user presses "Search N new items by meaning". With
every feature that saves items switched off (Writing checks alone), search by meaning does not run and
the search model is unloaded (`FeatureModel.search`).

**Models.** bge-small in the language helper (search only).

**Debug hooks.** `note`, `note-accept`, `note-copy`, `note-export`, `note-rewrite`, `search`,
`search-index`, `item`, `folder`. Environment: `CHIRP_EMBED_IDLE`.

## Home

The first page of the Library window (`Shell/HomePage.swift`, `Shell/HomeSections.swift`). A greeting
with the week's counts, a start bar with one action per switched-on feature, pinned items and folders as
tiles, then sections that show only when they have something: In progress, Coming up (calendar), Carry
on, Captured today, Try this. The lines are written by rule (`Packages/ChirpCore/.../Home/HomeLines.swift`).
Debug hooks: `home-seed`, `home-bird`, `home-tip`, `home-fixes`, `home-correct`.

## Library window

`Shell/LibraryWindow.swift`. One window: a glass sidebar (Home, All, Meetings, Notes, Dictations,
Documents, Dictionary, Snippets, Writing style, folders) and the page. Toolbar: sidebar button, Add
(files and links) and Search. An item's actions sit in its header (`Shell/ItemHeader.swift`).
Pages for switched-off features leave the sidebar; their items are kept. Folders and pins work across
kinds (`Shell/FolderPage.swift`). Closed at launch; opened from the perch, the menu bar, the Dock, or
right Option + O. Debug hooks: `open-main`, `close-main`, `section`, `open-item`, `window-size`,
`sidebar`, `transcript`, `more-menu`, `shot`.

## Settings

A page of the Library window, not a separate window (`Shell/SettingsView.swift`). Tabs: General (Dock and
menu bar, appearance, microphone, feature switches, permissions, onboarding again, Danger zone, version),
Perch, Dictation, Meetings, Notes, Reading, Writing, Models (sizes, licences, language model size, link
tool) and Shortcuts. A tab for a switched-off feature shows a note with a button back to the switches.
Debug hooks: `settings`, `settings-tab`, `features`, `language-size`, `danger`, `dock`, `appearance`.

## Onboarding

`Onboarding/OnboardingView.swift`, `Onboarding/OnboardingSteps.swift`, shown by `FirstRunWindow` in its
own small window on first run. Steps: Features, Dictation (try it), Shortcuts, Permissions, Models,
Language model, Writing, Notes, Recording, Reading; steps for switched-off features are left out. Each
step holds the real control, so what is set there is set for good. Nothing downloads until the user
starts it: the Dictation step shows the speech model's size with a button to download it, and the Models
step has a Download button per model and "Download all". Leaving it adds one short sample document to Home and opens the Library. Reopened from
Settings › General, it shows current values and resets nothing. Debug hooks: `onboarding`,
`onboarding-step`, `onboarding-do`; launch flag `--skip-onboarding`.

## Menu bar and perch

**Menu bar** (`Shell/MenuBarPopover.swift`, `Perch/MenuBarIcon.swift`). An `NSStatusItem` with the bird,
which shows what Chirp is doing. Its popover is a non-activating panel: what Chirp is doing with its
controls, action tiles (Dictate, Note, Read, Fix, Summarize, each only while its feature is on), the last
three items, quick settings, then Library, Settings and Quit. Debug hooks: `menu`, `menu-icon`,
`menu-shot`.

**Perch** (`Perch/`). A small glass bar at the bottom of the screen, over other apps, that never takes
focus unless a field in it is clicked. At rest it shows the bird and up to five actions (arranged in
Settings › Perch › Customize Perch, `ChirpCore/Engine/PerchArrangement.swift`). It grows to show live
state and results: dictation, a recording and its panel, reading, a summary, suggestions, the rewrite
panel, a note, a dropped file. It can sit in five places, stand at a side edge, hide in full screen,
and accepts dropped files (`Perch/PerchDrop.swift`). Debug hooks: `perch`, `perch-arrange`,
`perch-shot`, `drop`, `drop-do`, `file-drag`.
