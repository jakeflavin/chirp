# Development

How to get Chirp building from a fresh clone, run it, run a separate test copy, and find out what it did.
For tests see [TESTING.md](TESTING.md); for code rules see [CODING-STANDARDS.md](CODING-STANDARDS.md).

## Requirements

| Need | Why |
|---|---|
| A Mac with Apple Silicon | The models run on the Mac's GPU and Neural Engine. The project builds `arm64` only |
| macOS 26 or later | The deployment target |
| Xcode 27 | Builds the app and the Swift packages |
| Xcode's Metal Toolchain | MLX compiles Metal shaders. Xcode does not install it by default |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `Chirp.xcodeproj` is generated from `project.yml` and is not in git |
| Rust (`rustup`, `cargo`) | Builds the grammar checker library in `Rust/chirp-harper` |
| Homebrew | Optional; the bootstrap script uses it to install XcodeGen |

About 3 GB of free disk for the build, plus up to 4 GB for models the first time each feature is used.

## Set up

From the repository root:

```sh
Scripts/bootstrap.sh
```

It is safe to run again at any time. It does, in order:

1. Checks the Mac is Apple Silicon with macOS 26 or later.
2. Checks that Xcode 27 or later is selected.
3. Downloads the Metal Toolchain if it is missing: `xcodebuild -downloadComponent MetalToolchain`.
4. Installs XcodeGen with Homebrew if it is missing.
5. Checks that `cargo` is on the path.
6. Builds the grammar library: `Scripts/build-harper.sh` (writes `Rust/lib/libchirp_harper.a`).
7. Generates the project: `xcodegen generate`.

It stops with a message that says what to install when something is missing.

The same steps by hand:

```sh
sudo xcode-select -s /Applications/Xcode.app        # if another Xcode is selected
brew install xcodegen
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # if Rust is missing
xcodebuild -downloadComponent MetalToolchain
Scripts/build-harper.sh
xcodegen generate
```

Run `xcodegen generate` again after pulling changes to `project.yml`, or after adding or removing files in
`App/Sources`. Run `Scripts/build-harper.sh` again after changes in `Rust/chirp-harper`.

## Signing

Shared build settings (version, channel, signing defaults) are in `Config/Base.xcconfig`. Your own values go
in `Config/Local.xcconfig`, which is not committed. To sign with your Apple team:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# then set DEVELOPMENT_TEAM to your team id (Xcode › Settings › Accounts)
xcodegen generate
```

- With a team set, Xcode signs with your Apple Development certificate. macOS keeps permissions
  (Microphone, Accessibility, Screen Recording) across rebuilds.
- Without a team, the build is signed ad hoc. It runs, but macOS may ask for permissions again after each
  rebuild, because an ad hoc signature changes every time.
- CI builds with `CODE_SIGNING_ALLOWED=NO`.

## Build and run

Debug:

```sh
xcodebuild -project Chirp.xcodeproj -scheme Chirp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .dd \
  -skipMacroValidation -skipPackagePluginValidation build
open .dd/Build/Products/Debug/Chirp.app
```

Release (what `Scripts/e2e.sh` expects):

```sh
xcodebuild -project Chirp.xcodeproj -scheme Chirp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .dd \
  -skipMacroValidation -skipPackagePluginValidation build
open .dd/Build/Products/Release/Chirp.app
```

Or open `Chirp.xcodeproj` in Xcode and run the `Chirp` scheme.

Notes:

- Chirp starts with no window. It lives in the menu bar and the perch. Open the window from the menu bar
  bird, or with `open "chirp://show/speak"`.
- The first launch shows onboarding and asks for Microphone, Accessibility, call audio and Calendar.
- The speech model downloads during onboarding. Other models download the first time their feature is used.
- `CHIRP_CHANNEL` in `Config/Base.xcconfig` picks the channel. `Beta` sets the `BETA` compilation condition (a Beta
  tag in the UI) and the `AppIconBeta` icon set. Empty means a normal build. `Scripts/make-beta-icon.swift`
  makes the Beta icon set from the normal one.

### How the app is put together at run time

The app's executable is also every model helper. Started with one of these flags it runs as a helper and
never becomes an app (see `Main` in `App/Sources/Shell/ChirpApp.swift`):

| Flag | Helper |
|---|---|
| `--transcribe-worker` | speech to text |
| `--language-worker` | language model, search model, sentence checker |
| `--voice-worker` | reading voice |
| `--listen-worker voice-detection`, `--listen-worker speakers` | voice detection, speaker labelling |

`ps` shows them as children of the app while their model is loaded. The app starts and ends them; you never
start them by hand.

## Run a test copy

A test copy is a second Chirp that does not touch the installed one. Make one from a Release build:

```sh
COPY=/tmp/chirp-test/Chirp.app
mkdir -p /tmp/chirp-test && ditto .dd/Build/Products/Release/Chirp.app "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.chirp.test" "$COPY/Contents/Info.plist"
codesign -f -s - --deep "$COPY"
open -g -n "$COPY" --args --data-dir /tmp/chirp-test/data --skip-onboarding \
  --no-global-shortcuts --no-window --debug-hooks --muted-device-audio
```

Its own bundle id gives it its own preferences, and `chirp://` links can be sent to it with `open -a "$COPY"`.
`Scripts/e2e.sh` does all of this for you.

### Launch arguments

| Argument | Effect |
|---|---|
| `--data-dir <folder>` | Keeps the database, audio, documents and recording folders in `<folder>`. Models, tools and preferences are still shared |
| `--skip-onboarding` | Does not show onboarding, even on a new library |
| `--no-global-shortcuts` | Registers no global shortcuts, no hold key, and watches no keys or text in other apps. Use it whenever the installed Chirp is running |
| `--no-window` | Never opens the window by itself, even when a link arrives (each `open -a … chirp://…` counts as a reopen) |
| `--debug-hooks` | Turns on `chirp://debug/…` links. Without it they do nothing |
| `--ui-testing` | A library in memory, audio in a temporary folder, a silent reading clock, and the window opened at launch |
| `--muted-device-audio` | Reads aloud through the real audio path but with no sound |
| `--feed-audio <file.wav>` | Uses the file as the microphone |
| `--feed-system-audio <file.wav>` | Uses the file as the other side of a call |
| `--feed-screen <file.png>` | Uses the picture as the window read during a recording |

### Environment variables

Pass them with `open --env NAME=value`.

| Variable | Effect |
|---|---|
| `CHIRP_LOG=<file>` | Writes the log to `<file>` instead of `~/Library/Logs/Chirp/chirp.log` |
| `CHIRP_EMBED_IDLE=<seconds>` | Ends a helper kept only for search sooner (default 240) |
| `CHIRP_VOICE_KEEP=<seconds>` | Ends the voice's helper sooner after the voice is put away (default 600) |
| `CHIRP_TTS_DIR=<folder>` | Looks for the reading voice in another folder, to test a missing or partial download |
| `CHIRP_WORKER_FAULT=<fault>` | Makes the speech helper fail in a set way, to test recovery |
| `CHIRP_RECORD_TEST=<name=value,…>` | With `--debug-hooks`: test switches for recording (`notes=0` skips writing notes, `headphones=1`, `stall=system`, `stepLimit=<n>`, `notesHold=<seconds>`) |
| `CHIRP_SYSTEM_AUDIO=<status>` | With `--debug-hooks`: pretends the call audio permission is in that state |
| `CHIRP_TOOLS_DIR`, `CHIRP_LINKTOOL_BASE` | With `--debug-hooks`: where the link tool is kept and downloaded from |
| `CHIRP_RESET_PLACES=<path:path>` | With `--debug-hooks`: what "Reset Chirp completely" removes in a copy with its own data folder (a copy never removes the shared models) |

## Logs

```sh
tail -f ~/Library/Logs/Chirp/chirp.log
```

Each line is `time [area] message`. The log holds sizes, timings and outcomes, never what was said, typed or
read. It starts again when it passes 1 MB. A test copy should use `CHIRP_LOG` so its lines stay separate.

Settings › General has "Show the log", which opens the folder in Finder.

## Debug links

With `--debug-hooks`, the app answers `chirp://debug/<command>?<arguments>` links. They let a script drive the
app and read its state without screen recording or automation permissions. Send them to a test copy with
`open -g -a <copy> "chirp://debug/…"`.

`chirp://show/<page>` (`speak`, `record`, `write`, `read`, `remember`) works in every build and opens the window there.

The most used:

| Link | What it does |
|---|---|
| `state?path=<file>` | Writes the app's state as JSON: each feature's part, models, helpers, the window, the perch |
| `shot?path=<file>&mode=cache\|layer\|screen` | Pictures every visible Chirp window to `<file>.png`, `<file>-2.png`, … |
| `features?all=1`, `features?dictate=0` | Switches features as Settings does |
| `seed` | Adds example words, snippets, styles and a small library |
| `section?name=<section>`, `settings-tab?name=<tab>` | Shows a page of the window |
| `open-main`, `close-main`, `window-size?w=&h=`, `sidebar?show=0\|1` | The window |

All commands by area (each file's comments give the arguments):

| Area | Commands | Registered in |
|---|---|---|
| App and window | `state`, `shot`, `icon`, `settings`, `section`, `seed`, `toast`, `sound-check`, `appearance`, `onboarding`, `onboarding-step`, `options`, `language-size`, `write-card`, `close-main`, `open-main`, `settings-tab`, `open-item`, `transcript`, `window-size`, `sidebar`, `dock`, `menu-bar` | `Shell/DebugHooks.swift`, `Shell/ChirpApp.swift` |
| Features and shortcuts | `features`, `right-option` | `Shell/FeatureSwitches.swift`, `Shell/ShortcutLayout.swift` |
| Home and onboarding | `home-tip`, `home-seed`, `home-correct`, `home-bird`, `home-fixes`, `onboarding-do` | `Shell/HomeSections.swift` |
| Menu bar | `menu`, `menu-shot`, `menu-icon` | `Shell/MenuBarPopover.swift` |
| Dictation and links | `dictate`, `stop`, `cancel`, `key`, `hold-key`, `editlast`, `transcribe`, `retranscribe-kept`, `transcribe-link`, `link-choose`, `link-cancel`, `link-tool`, `link-ask`, `import-cancel` | `Speak/DictationController.swift` |
| Recording | `meeting-start`, `meeting-note`, `meeting-capture`, `meeting-stop`, `meeting-attach`, `meeting-detach`, `meeting-notes-stop`, `meeting-redo`, `meeting-import`, `call-name`, `mic-trial`, `job-hold`, `job-cancel`, `meeting-offer`, `meeting-offer-accept`, `calendar-fake` | `Record/MeetingRecorder.swift`, `Record/MeetingDetector.swift`, `Services/CalendarReader.swift` |
| Notes | `note`, `note-export`, `note-copy` | `Notes/NoteController.swift` |
| Writing | `write-set`, `write-fixall`, `write-caret`, `write-deep`, `write-run`, `write-accept`, `write-act`, `panel`, `panel-run`, `panel-close`, `panel-again`, `panel-snippet`, `fix-sentence`, `underline-seed`, `underline-apply`, `underline-fixall`, `underline-reset`, `underline-card`, `card-shot`, `bird-shot`, `bird-click`, `note-rewrite`, `note-accept` | `Write/` |
| Reading and documents | `read-file`, `read-text`, `read-web`, `read-play`, `read-pause`, `read-stop`, `read-dismiss`, `read-skip`, `read-selection`, `read-once`, `read-jump`, `read-speed`, `read-export`, `read-summarize`, `read-show-summary`, `read-brackets`, `read-citations`, `read-unload`, `read-roundtrip`, `say-it-as`, `folder`, `item`, `doc-view`, `summary-seed`, `summary-fold`, `copy-check`, `read-page`, `doc-transcript`, `doc-keep`, `link-kind` | `Read/ReadController.swift`, `Read/DocumentDebug.swift` |
| Perch | `perch`, `drop`, `drop-do`, `perch-arrange`, `summarize-here`, `more-menu`, `perch-shot`, `file-drag` | `Perch/PerchController.swift`, `Perch/PerchDrop.swift` |
| Search | `search`, `search-index` | `Remember/SearchController.swift` |
| Models and helpers | `helper-fault`, `llm-fault`, `llm-worker` | `Services/ModelCenter.swift` |
| Settings › Danger zone | `danger` | `Services/DangerZone.swift` |

## Troubleshooting

**A test copy has no permissions.** macOS ties Microphone, Accessibility and Screen Recording to the app's
signature and bundle id. A copy with its own bundle id, signed ad hoc, starts with none. Scripts that drive
it with `--feed-audio` and debug links do not need any. To try permissions by hand, grant them to that copy
in System Settings › Privacy & Security, or run the installed app. If a grant seems stuck after a rebuild,
remove the app from the list and add it again, or run `tccutil reset Accessibility <bundle id>`.

**Two Chirps answer the same key.** Start the test copy with `--no-global-shortcuts`.

**Links go to the wrong copy.** A bare `open "chirp://…"` goes to whichever Chirp macOS picks. Use
`open -g -a <path to the copy> "chirp://…"`.

**A test copy stops answering links after a while.** macOS slows down apps nobody is looking at (App Nap). A
copy started with `--debug-hooks` asks to stay awake; check that the flag is there.

**`cannot execute tool 'metal' due to missing Metal Toolchain`.** Run
`xcodebuild -downloadComponent MetalToolchain`, then build again.

**`library 'chirp_harper' not found` or `no such module 'ChirpHarper'`.** The Rust library has not been
built. Run `Scripts/build-harper.sh`. It needs `cargo`; install Rust with `rustup` first.

**`Signing for "Chirp" requires a development team`.** Either set `DEVELOPMENT_TEAM` in
`Config/Local.xcconfig`, or build with `CODE_SIGNING_ALLOWED=NO` and run it unsigned.

**`Chirp.xcodeproj` is missing or out of date.** Run `xcodegen generate`.

**Package resolution fails.** Delete `.dd/SourcePackages` and build again. Check you are online: the first
build downloads the Swift packages and the speech engine's prebuilt framework.

**Dictation is slow right after the first install.** macOS prepares the speech model in the background for a
few minutes after it is first loaded. The log shows `speech model probe` lines until it answers quickly.

**Something failed and the window says nothing.** Read `~/Library/Logs/Chirp/chirp.log`.
