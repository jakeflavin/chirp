# Working on Chirp

These are the rules for anyone changing Chirp, people and coding agents alike. Read this file first, then the doc for the area you're touching. Where code and docs disagree, the docs say what should be true: fix the code, or update the doc in the same change.

## What Chirp is

A native Mac app (Swift, SwiftUI, AppKit) that helps with your own words: Dictate, Record meetings and voice notes, Write checks, Read aloud, Summarize, and Notes with search. Every model runs on the user's Mac.

**Scope:** Mac only (Apple Silicon, macOS 26+), English only, one person's own Mac. No servers, accounts, sync, sharing or other platforms.

## Never

- **Never send user content off the Mac.** That covers text, audio, recordings, documents and screen contents. The only network calls are the ones listed in [Docs/PRIVACY.md](Docs/PRIVACY.md). A new one must be added there in the same change.
- **Never load a model in the app process.** Model work runs in a helper process. Build new helpers on `ModelHelper` ([Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)).
- **Never use Apple Intelligence or Apple's Foundation Models.** Chirp uses open models only ([Docs/MODELS.md](Docs/MODELS.md)).
- **Never write content for the user.** Prompts fix, rephrase, shorten, join or summarize what the user gave.
- **Never use SF Symbols.** Use Chirp's own icon set, `Image("chirp.name")` ([Docs/DESIGN.md](Docs/DESIGN.md)).
- **Never log what the user said, typed, selected or read.** Log sizes, timings and outcomes only.
- **Never commit personal data, keys, signing settings or machine paths.** `Config/Local.xcconfig` is ignored for a reason.
- **Never let a switched-off feature do anything** ([Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md#feature-switches)).

## Read before you touch

| You're changing | Read |
|---|---|
| Anything | [Docs/CODING-STANDARDS.md](Docs/CODING-STANDARDS.md) |
| Where code goes, processes, helpers, `ModelCenter`, app lifecycle | [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) |
| A feature's behaviour or flow | [Docs/FEATURES.md](Docs/FEATURES.md) |
| UI: the perch, windows, colour, type, icons, motion, copy, accessibility | [Docs/DESIGN.md](Docs/DESIGN.md) |
| The database, migrations, files on disk | [Docs/DATA-MODEL.md](Docs/DATA-MODEL.md) |
| Models: adding, swapping, loading, memory | [Docs/MODELS.md](Docs/MODELS.md) |
| Network calls or permissions | [Docs/PRIVACY.md](Docs/PRIVACY.md) |
| Building, running a test copy, debug links | [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md) |
| Tests and fixtures | [Docs/TESTING.md](Docs/TESTING.md) |
| Versions, channels, CI releases | [Docs/RELEASING.md](Docs/RELEASING.md) |
| Ideas we might build later | [Docs/IDEAS.md](Docs/IDEAS.md) |

## Layout

```
App/            the app: one folder per feature (Sources/<Feature>), resources, Info.plist
Packages/
  ChirpCore/    pure logic and storage (GRDB). Has the unit tests. Imports no UI and no models.
  ChirpML/      model runtimes and the helper processes
  TranscribeCpp/ the speech engine's Swift bindings
Rust/           the Harper grammar checker, built into a static library
Config/         build settings: versions, beta channel, signing
Fixtures/       test inputs (see Fixtures/README.md)
Scripts/        bootstrap, Harper build, end-to-end checks, release
Site/           the website and the update feed
Docs/           the docs above
```

## Set up and check a change

```bash
Scripts/bootstrap.sh                       # once, and after pulling changes to project.yml or Rust/
cd Packages/ChirpCore && swift test        # logic and storage
```

Build and run as shown in [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md). Before you call a change done:

1. Unit tests pass, and new logic in `ChirpCore` has a test.
2. The app builds with no new warnings.
3. You tried it in a test copy of the app (`--data-dir`), not only in tests. UI changes are checked in light and dark.
4. `Scripts/e2e.sh` passes for the area you touched (`ONLY=…`), if it has a check there.
5. Docs are updated if behaviour, architecture, a setting, a permission or a network call changed.

## Style in one breath

Plain, short user-facing text. `@MainActor @Observable` classes for UI state. Errors are typed and logged with `Log.write`. Comments say why, in full sentences, and make sense on their own: no ticket ids, dates or names. Match the code around you. [Docs/CODING-STANDARDS.md](Docs/CODING-STANDARDS.md) has the details.
