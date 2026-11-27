# Privacy

Chirp runs on your Mac. Your voice, your recordings, your text and your documents are processed on
this Mac by models that run on this Mac. Chirp has no account, no server, no analytics and no crash
reporting.

This page lists every time Chirp uses the network, every permission it asks for, and every place it
keeps data. The first half is for people using Chirp; the last section is the rule for contributors.

## What never leaves your Mac

- What you say: microphone audio, dictations, voice notes, meeting audio and transcripts.
- The sound of calls captured from the Mac (System Audio Recording).
- Text Chirp reads in other apps for writing checks, text you select to rephrase, read aloud or
  summarize, and anything Chirp types for you.
- Your notes, summaries, meeting notes, documents, dictionary, snippets and writing style.
- Your calendar events. They are read to name meetings and are never sent anywhere.
- Window pictures kept during a recording, and the text read from them (Apple's Vision framework,
  on this Mac).
- Search queries and the search index.
- The log. It records sizes, timings and outcomes, never what was said, typed or selected.

No model is sent your data. Models are downloaded to the Mac and run there.

## When Chirp uses the network

There are two kinds of network use: downloading models and tools, and fetching something you asked for
(a link or a web page). Each is listed below. Showing a saved web page uses none.

What every request sends, unless noted: your IP address, the address being fetched, and standard HTTP
headers. Chirp adds no identifiers, cookies or account details of its own. Where Chirp sets its own
User-Agent, it is listed.

### Model and tool downloads

| What | When | To | What is sent | Code |
|---|---|---|---|---|
| Speech model (Parakeet, 730 MB) | When you press Download in onboarding (which shows its size first), or the first time dictation, a recording or an import needs it | `huggingface.co` (and the download host it redirects to) | A GET for one pinned file. Default system User-Agent | `Transcriber.download` in `Packages/ChirpML/Sources/ChirpML/Transcriber.swift` |
| Language model (Qwen3.5, 1.6 to 6 GB by size) | The first time a rewrite, meeting notes, a deeper writing check or a summary needs it | `huggingface.co` | Hub API and file requests from the swift-huggingface downloader. If a Hugging Face token is present in the environment or the Hugging Face cache, the library may send it (verify) | `LanguageEngine.load` in `ChirpML/LanguageEngine.swift` |
| Summary model and its adapter (0.7 GB) | The first summary, on Macs whose language model is the 2B | `huggingface.co` | Same as above | `LanguageEngine.load` (with `adapterID`) |
| Search model (bge-small, 130 MB) | When you turn on search by meaning | `huggingface.co` | Same as above | `EmbedEngine.load` in `ChirpML/EmbedEngine.swift` |
| Reading voice (Kokoro, 95 MB) | The first time you use Read aloud | `huggingface.co`, through FluidAudio | FluidAudio's own requests | `VoiceEngine.load` in `ChirpML/VoiceEngine.swift` |
| Other voices (about 0.5 MB each) | In the background, after the voice first loads, for any voice not yet on the Mac | `huggingface.co`, through FluidAudio | Same | `Voice.fetchMissingVoices` in `ChirpML/Voice.swift` |
| British word list (about 10 MB) | The first time a British voice speaks. Retried after 5 minutes if offline | `huggingface.co`, through FluidAudio | Same | `VoiceEngine.britishWordList` |
| Voice detection (Silero) | With the speech model | `huggingface.co`, through FluidAudio | Same | `VoiceDetectionEngine.load` in `ChirpML/ListenEngine.swift` |
| Speaker labelling (pyannote, 100 MB) | The first time a meeting is finished with speakers told apart | `huggingface.co`, through FluidAudio | Same | `SpeakerEngine.load` in `ChirpML/ListenEngine.swift` |
| Link tool (yt-dlp) | The first video page link, Download or Update in Settings › Models, or once more when a page link fails and a newer release exists | `github.com/yt-dlp/yt-dlp/releases/latest/download/` (and GitHub's download host) | GETs for `SHA2-256SUMS` and `yt-dlp_macos`. User-Agent `Mozilla/5.0 (Macintosh) transcription-app` | `LinkImporter.installTool` in `App/Sources/Record/LinkImporter.swift` |
| Sentence checker (MiniCheck) | Downloaded in the background the first time a summary runs without it | `huggingface.co/jakeflavin/minicheck-roberta-large` | Plain file requests, nothing about the user | `SummaryCheckerDownload.swift` |

### Things you ask Chirp to fetch

| What | When | To | What is sent | Code |
|---|---|---|---|---|
| A link to transcribe | You paste or add a link (the Library's Add) | The address you gave | A GET; the first 600 bytes are read to tell a sound file, a podcast feed or a web page apart. User-Agent `Mozilla/5.0 (Macintosh) transcription-app` | `LinkImporter.sort` |
| A sound file or podcast episode from that link | Right after, if it is a file or you pick an episode | The file's address | A GET for the file. Saved to a temporary file, deleted once transcribed | `LinkImporter.transcribeFile`, `download` |
| A video page, through yt-dlp | Right after, if the link is a page | The page's site and whatever hosts yt-dlp uses to get its sound | yt-dlp's own requests. Run with `--no-update --ignore-config --no-playlist`; no cookies or logins are passed | `LinkImporter.fetchWithTool`, `LinkTool.arguments` in `ChirpCore/Meetings/MediaLinks.swift` |
| A web page to read or summarize | You type or paste an address to import | The address you gave | A GET. User-Agent `Mozilla/5.0 (Macintosh) Chirp reader` | `DocumentImporter.importWebPage` in `App/Sources/Read/DocumentImporter.swift` |
| Pictures in that page | Right after, when "keep pictures" is on (the default) | Each picture's own address, up to 120 pictures | A GET per picture. Same User-Agent | `DocumentImporter.stageWebImages`, `imageData` |
| A saved copy of that page | Right after, when "keep the original" is on (the default) | The page and everything it loads | The page is loaded once in an off-screen web view with no stored data (non-persistent) and its scripts off, so the page's analytics and other scripts do not run. The pictures, style sheets and frames the page itself names are fetched, as a browser would | `PageSaver.archive` in `App/Sources/Read/DocumentFiles.swift` |
| Fetch the original again | You press it on a web page saved without one | The page's saved address | Same as the saved copy; falls back to a plain GET | `OriginalFetch.fetch` in `App/Sources/Read/FetchOriginal.swift` |

### Showing a saved web page

The Original view of a saved web page (`SavedPage` in `App/Sources/Read/OriginalView.swift`) shows the
saved copy with scripts off and no stored data, and fetches nothing from the web: content rules
(`SavedPageRules` in `ChirpCore/Reading/SavedPageRules.swift`) block every web address except those
saved in the copy. A picture or style sheet that was not saved is left out. Clicking a link opens it in
your browser.

Links you click anywhere in Chirp (a meeting's calendar links, links in a document) open in your
default browser. Chirp does not fetch them itself.

### Coming with the first public release

| What | When | To | What is sent |
|---|---|---|---|
| Update check (Sparkle) | Periodically, and when you choose Check for Updates | `https://jakeflavin.github.io/chirp/appcast.xml`, then the update file it names | Sparkle's standard request: app version, macOS version. No system profile (to be configured that way) |
| Feedback links | Only when you click one | GitHub issue pages, opened in your browser | Nothing from Chirp; your browser opens the page |

Neither exists in the code yet. This table will be updated when they land.

### What Chirp never does over the network

- Send audio, transcripts, text, documents, notes, calendar data, screen pictures or search queries.
- Send analytics, usage counts, crash reports or device identifiers.
- Call any language model or speech service in the cloud.

## Permissions

Chirp asks for each permission when a feature first needs it, and in onboarding. You can change any
of them in System Settings › Privacy & Security.

| Permission | Why | Asked by | Without it |
|---|---|---|---|
| Microphone | To hear you: dictation, voice notes, your side of a meeting | `Permissions.requestMicrophone` (`App/Sources/Services/Permissions.swift`) | Nothing can be dictated or recorded |
| Accessibility | To type into other apps, read the selected text, read text fields for writing checks and underlines, read where text is on screen for highlighting while reading aloud, and watch the dictation key in other apps | `Permissions.requestAccessibility` | Dictated text is left on the clipboard with a message; writing checks in other apps, the hold-to-talk key and reading a selection do not work |
| System Audio Recording ("Call audio") | To hear the other side of a meeting or call, through a Core Audio process tap | `Permissions.requestSystemAudio` starts a capture for 2 seconds so macOS asks; a sound check confirms it | Meetings record only your microphone |
| Calendars (full access) | To name meeting recordings and know who is invited, and to offer to record when a meeting starts. Read-only | `CalendarReader.requestAccess` (`App/Sources/Services/CalendarReader.swift`) | Meetings are named by the call app or time |
| Screen Recording | To keep a picture of the front window during a recording when you press the camera button, and read its text on the Mac | `ScreenReader.ask` when the camera button is first pressed (`MeetingRecorder.capture`) | The camera button cannot keep pictures |

Notes:

- Password fields are never read: secure text fields are skipped by the writing checks
  (`UnderlineController`), and sign-in fields are detected and left alone (`SignInField`). Windows of
  password managers and System Settings are never pictured (`ScreenReader.privateApps`).
- To insert text, Chirp puts it on the clipboard, sends ⌘V, and puts your clipboard back once the app
  has read it (`TextInserter`). Clipboard history tools may see the text for that moment.
- To read the selection in some apps, Chirp sends ⌘C and puts the clipboard back afterwards.
- Chirp checks whether System Audio Recording is allowed through a private macOS function
  (`TCCAccessPreflight`, `App/Sources/Services/SystemAudioPermission.swift`), because there is no
  public one. It only reads the answer.
- Chirp watches global key and mouse events (`NSEvent` global monitors) for the dictation key, the
  perch following the pointer, and file drags. It does not log keys.
- The app is not sandboxed. Its entitlements are audio input and calendars (`App/Chirp.entitlements`)
  with the hardened runtime on.

## Where data lives

| What | Where |
|---|---|
| Library database (items, transcripts, notes, dictionary, snippets, style, most settings, search index) | `~/Library/Application Support/Chirp/chirp.sqlite`. Copies named `chirp-before-*.sqlite` may exist from development builds; the app does not make them, but Delete my library removes them |
| Dictation and recording audio, pictures kept during recordings | `~/Library/Application Support/Chirp/Audio/` |
| Imported documents (originals, saved pages, pictures) | `~/Library/Application Support/Chirp/Documents/` |
| Files attached to recordings | `~/Library/Application Support/Chirp/Attachments/` |
| A recording in progress, recordings left to finish, audio that could not be saved | `~/Library/Application Support/Chirp/Recording in progress/`, `Recordings to finish/`, `Recording audio not saved/` |
| Speech model, sentence checker | `~/Library/Application Support/Chirp/Models/` |
| Link tool | `~/Library/Application Support/Chirp/Tools/` |
| Language, summary and search models | `~/.cache/huggingface/hub/` |
| Reading voice and word lists | `~/.cache/fluidaudio/Models/` |
| Voice detection and speaker labelling | `~/Library/Application Support/FluidAudio/Models/` |
| Preferences (feature switches, model choices, window and perch options) | `~/Library/Preferences/<bundle id>.plist` |
| Log (no content; replaced when it passes 1 MB) | `~/Library/Logs/Chirp/chirp.log` |
| Files being imported, link audio being transcribed | The system temporary folder (`chirp-import-*`), deleted when done or at next launch |

Settings › General › Danger zone has **Delete my library** (every item, its audio and files, and folders;
keeps dictionary, snippets, style and settings) and **Reset Chirp completely** (the whole database and the
downloaded models and link tool). See `DataReset` and `DangerZone` for exactly what each removes.

## Rule for contributors

- **Any new network call must be added to this file** in the same pull request: what, when, to where,
  what is sent, and the code location. This includes calls made by a library you add (a model
  downloader, an update checker) and web views that load remote content.
- Set a plain User-Agent with nothing about the Mac or its owner.
- Never send user content off the Mac. No cloud models, analytics or crash reporting.
- Never put content (what was said, typed, selected or read) in the log.
- A new permission needs a usage string in `project.yml`, a row in `PermissionRows`, and a row in the
  table above.
- Pin downloads to a revision and check a size or hash where the source allows.
