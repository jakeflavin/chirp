# Data model

Chirp keeps everything on the Mac: one SQLite database, opened with [GRDB](https://github.com/groue/GRDB.swift),
and a few folders of files beside it. This page describes both.

The code is in `Packages/ChirpCore/Sources/ChirpCore/Store`:

| File | What it holds |
|---|---|
| `ChirpStore.swift` | Opens the database, the migrations, the folder locations, the built-in note templates |
| `Records.swift` | One Swift record type per table |
| `Library.swift` | Saved items: save, list, delete, folders, templates, transcripts, keyword search, passages for search by meaning |
| `SemanticSearch.swift` | Passages, vectors and the merged ranking of keyword and meaning results |
| `Corrections.swift` | Counted corrections of single words |
| `DataReset.swift` | "Delete my library" and "Reset Chirp completely" |
| `../Engine/PersonalLanguage.swift` | Dictionary, snippets, app styles, dismissed rules, the `setting` table, profile export |

## Opening the database

```swift
let store = try ChirpStore(url: ChirpStore.defaultURL)   // ~/Library/Application Support/Chirp/chirp.sqlite
let store = try ChirpStore()                             // in memory, for tests and --ui-testing
```

`ChirpStore` holds one `DatabaseQueue`, so writes never overlap. Opening it runs every migration that has
not run yet, then adds the built-in note templates to an empty `noteTemplate` table. Foreign keys are on
(GRDB's default).

## Tables

Types below are the SQLite column types GRDB declares. `datetime` columns hold GRDB's date text.
"Not null" is marked with `!`.

### Library

#### `item`: everything saved

One row per dictation, voice note, meeting, document or legacy draft. Record type `SavedItem`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer, primary key | |
| `kind` | text `!`, indexed | `ItemKind`: `dictation`, `voiceNote`, `meeting`, `document`, `note` (a draft kept from an old page, listed with documents) |
| `title` | text `!` | Shown title. Made from the first words when saved empty |
| `body` | text `!` | Main text: the cleaned dictation, a document's text, a meeting's notes, a note's words without Markdown |
| `rawText` | text `!` | The uncleaned transcript of a dictation, or the user's own raw notes in a meeting |
| `summary` | text `!` | A summary in Markdown, when one was made |
| `folderID` | integer | `folder.id`, set to null when the folder is deleted |
| `audioFile` | text | File name inside the `Audio` folder, when sound was kept |
| `duration` | double `!` | Length of the recording in seconds; 0 when there is none |
| `appBundleID` | text | The app dictated into, or the app the call ran in |
| `source` | text | Where a document came from (file path or URL). For a meeting: invited people's names from the calendar, comma separated |
| `position` | integer `!` | Reading position, a UTF-16 offset into `body` |
| `starred` | boolean `!` | Pinned |
| `createdAt` | datetime `!`, indexed | |
| `updatedAt` | datetime `!` | Set on every save |
| `context` | text `!`, default `''` | For a recording: `RecordingContext` as JSON (calendar event, attendees, call app, attachments, screen text read during the recording, timed notes, template, kind). Empty otherwise |

#### `transcriptSegment`: what was said, line by line

Record type `TranscriptSegment`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer, primary key | |
| `itemID` | integer `!`, indexed | `item.id`, cascade delete |
| `speaker` | text `!` | "Me", "Speaker 2", or a name the user gave |
| `start`, `end` | double `!` | Seconds from the start of the recording |
| `text` | text `!` | The words |

Replace a transcript only with `Library.replaceSegments(itemID:with:)`. It also rewrites `itemTranscript`.

#### `itemTranscript`: a recording's words as one text

| Column | Type | Meaning |
|---|---|---|
| `itemID` | integer, primary key | `item.id`, cascade delete |
| `text` | text `!` | All segments in order, one per line, for keyword search |

#### `itemAttachment`: text of files attached to a recording

| Column | Type | Meaning |
|---|---|---|
| `itemID` | integer, primary key | `item.id`, cascade delete |
| `text` | text `!` | Text read from the attached files, for keyword search. Written by `Library.setAttachmentText` |

#### `itemDocument`: what a document keeps beside its text

Record type `DocumentExtra`. A document without a row is shown as plain text.

| Column | Type | Meaning |
|---|---|---|
| `itemID` | integer, primary key | `item.id`, cascade delete |
| `layout` | text `!`, default `''` | `DocLayout` as JSON (headings, lists, images); empty for plain text |
| `files` | text | Folder name inside `Documents` that holds this document's files |
| `original` | text | File name of the original (PDF, Word file, saved web page) in that folder |
| `site` | text `!`, default `''` | A saved page's site name, when known |
| `format` | text `!`, default `''` | What the list says it is: "PDF", "EPUB", "Word", "Web page", "YouTube", "Podcast", "Audio", "Text" |
| `pages` | integer `!`, default 0 | Page count for a file that has pages |
| `summaryCollapsed` | boolean `!`, default false | The summary panel was left folded |

#### `itemNote`: a note's Markdown

Record type `NoteExtra`. Every note is an item of kind `voiceNote`, typed or spoken.

| Column | Type | Meaning |
|---|---|---|
| `itemID` | integer, primary key | `item.id`, cascade delete |
| `markdown` | text `!` | The note as written, in Markdown |
| `typed`, `dictated` | boolean `!`, default false | Whether anything was typed, or dictated, into it |
| `editedAt` | datetime | Last edited by hand; null for a voice note never edited |
| `exportedAt` | datetime | Last exported or shared |

#### `todoDone`: ticked to-dos in a recording's notes

| Column | Type | Meaning |
|---|---|---|
| `itemID` | integer `!`, indexed | `item.id`, cascade delete |
| `key` | text `!` | The to-do's own words, so it stays ticked when the notes are shown again |
| `doneAt` | datetime `!` | |

Primary key: (`itemID`, `key`).

#### `chunk`: passages for search by meaning

Record type `Chunk`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer, primary key | |
| `itemID` | integer `!`, indexed | `item.id`, cascade delete |
| `offset` | integer `!` | Character offset of the passage in the item's searchable text |
| `text` | text `!` | The passage (about 700 characters, overlapping) |
| `embedding` | blob `!` | The search model's vector as little-endian Float32; empty until embedded |

#### `folder`

Record type `Folder`. Columns: `id`, `name` text `!`, `createdAt` datetime `!`.

#### `noteTemplate`: shapes for meeting notes

Record type `NoteTemplate`. Columns: `id`, `name` text `!`, `sections` text `!` (one heading per line),
`builtIn` boolean `!`. Five built-in templates are added to an empty table: General, One-on-one, Stand-up,
Customer call, Interview.

### The user's language

#### `dictionaryEntry`: words Chirp should spell the user's way

Record type `DictionaryEntry`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer, primary key | |
| `term` | text `!` | The right spelling. Kept once whatever its capitals (merged in code) |
| `soundsLike` | JSON text `!` | What speech recognition tends to write instead |
| `pronunciation` | text | How the reading voice should say it, if different |
| `origin` | text `!` | `manual` or `learned` |
| `originNote` | text | For a learned word, where it came from |
| `enabled` | boolean `!` | |
| `createdAt` | datetime `!` | |

#### `snippet`: spoken cues that expand to saved text

Columns: `id`, `cue` text `!`, `text` text `!`, `enabled` boolean `!`, `createdAt` datetime `!`.

#### `appStyle`: formality and underlines per app

| Column | Type | Meaning |
|---|---|---|
| `id` | integer, primary key | |
| `bundleID` | text `!`, unique | The app |
| `appName` | text `!` | Its name as shown |
| `formality` | text `!` | `casual`, `neutral` or `formal` |
| `underlinesEnabled` | boolean `!` | Live underlines in this app |
| `origin` | text `!` | `manual` or `learned` |
| `updatedAt` | datetime `!` | |

#### `dismissedRule`: suggestions the user turned off

Columns: `id`, `ruleKey` text `!` (the checker's rule id), `text` text (when set, only this text is exempt;
when null, the whole rule is off), `createdAt` datetime `!`.

#### `correction`: single words the user put right

Record type `Correction`. Only the two words are kept, never the text around them.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer, primary key | |
| `wrong` | text `!` | The word as written |
| `right` | text `!` | The word it was changed to |
| `times` | integer `!`, default 1 | How often |
| `lastAt` | datetime `!` | |

Unique: (`wrong`, `right`).

#### `setting`: preferences that belong with the library

Record type `SettingRow` (internal). Read and write through `PersonalLanguage.setting(_:as:)` and
`setSetting(_:_:)`; values are JSON.

| Column | Type | Meaning |
|---|---|---|
| `key` | text, primary key | |
| `value` | text `!` | JSON |
| `origin` | text `!` | `manual` or `learned` |
| `updatedAt` | datetime `!` | |

Keys in use: `writingProfile`, `onboardingDone`, `adoptedOldVoiceNotes`, `dictationHistoryLimit`,
`holdKey`, `keepDictationAudio`, `keepMeetingAudio`, `keepNoteAudio`, `keepMicReady`,
`longDictationPieceSeconds`, `readSkipBrackets`, `readSkipCitations`, `readSpeed`,
`readVoice`, `tellSpeakersApart`, `writeDraft`.

Window, device and display preferences are in `UserDefaults` instead. See
[CODING-STANDARDS.md](CODING-STANDARDS.md#settings-and-feature-switches).

## Relations

```
folder 1 ──< item            (item.folderID, ON DELETE SET NULL)
item   1 ──< transcriptSegment, chunk, todoDone      (ON DELETE CASCADE)
item   1 ──1 itemTranscript, itemAttachment, itemDocument, itemNote   (ON DELETE CASCADE)
```

The language tables (`dictionaryEntry`, `snippet`, `appStyle`, `dismissedRule`, `correction`, `setting`)
stand alone.

## Search

### Keyword search (FTS5)

Three FTS5 tables, each kept in step with its source table by SQLite triggers that GRDB's
`synchronize(withTable:)` creates. All use the Porter stemmer over the `unicode61` tokenizer.

| FTS table | Mirrors | Columns | Weight in results |
|---|---|---|---|
| `itemFTS` | `item` | `title`, `body`, `rawText`, `summary` (bm25 weights 4, 1, 0.6, 1.5) | first |
| `transcriptFTS` | `itemTranscript` | `text` | 0.6 |
| `attachmentFTS` | `itemAttachment` | `text` | 0.3 |

`Library.search(_:kinds:limit:)` quotes each word and makes the last a prefix, so user input can never be
read as FTS syntax. An item is listed once, from the first table that found it.

### Search by meaning (vectors)

There is no vector index. `chunk.embedding` holds one vector per passage, and `SemanticSearch.nearest`
compares the query vector with every stored one by dot product. A personal library is small enough for this
to take milliseconds.

- `Library.save` deletes an item's chunks when its `body`, `summary` or `rawText` changes, so it is embedded again.
- Dictations are not embedded.
- `SemanticSearch.fuse` merges keyword and meaning results by reciprocal rank fusion.
- Vectors from different models cannot be compared. Changing `Embedder.modelID` means deleting every chunk
  so everything is embedded again.

## Migrations

Migrations are registered in order in `ChirpStore.migrator`. Each is one named step.

| Step | Change |
|---|---|
| `v1` | All the base tables and `itemFTS` |
| `v2` | `item.context` |
| `v3` | `todoDone` |
| `v4` | `itemTranscript` and `transcriptFTS`, filled from existing segments |
| `v5` | `itemAttachment` and `attachmentFTS`, filled from existing recording contexts |
| `v6` | `itemDocument` |
| `v7` | `correction` |
| `v8` | `itemNote`, with a row for every existing voice note |

### Adding a migration

1. Add a new step at the end of `migrator` with the next name (`v9`). **Never edit a step that has shipped**,
   and never reorder steps.
2. Change the layout with GRDB's schema API (`db.create(table:)`, `db.alter(table:)`). A new non-null column
   on an existing table needs a default: `t.add(column: "x", .text).notNull().defaults(to: "")`.
3. If existing rows need data, fill it in the same step with SQL. Leave rows the user already has unchanged
   unless the step's purpose is to change them.
4. Prefer a new table keyed by `itemID` over more columns on `item` for data only some kinds of item have
   (as `itemDocument` and `itemNote` do).
5. Update the record type in `Records.swift`. A new stored property needs a default in `init` so existing
   call sites keep working.
6. Add a comment above the step saying what it adds and why, in plain words.
7. Add a test that opens a database file at the previous step, saves data the old way, then opens it fully
   and checks the data came through:

   ```swift
   let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
   do {
       let store = try ChirpStore(url: url, upTo: "v8")
       // insert rows the way v8 had them
   }
   let library = Library(store: try ChirpStore(url: url))
   // check the new step's result
   ```

Also:

- Never rename a stored enum case (`ItemKind`, `Origin`, `Formality`); the raw value is what is on disk.
- Never rename or drop a column in place. Add the new one, copy the data, and stop reading the old one.
- Keep FTS tables in step through `synchronize(withTable:)`, or through the one function that writes their
  source (`replaceSegments`, `setAttachmentText`).

## Files on disk

Everything is under the user's account. Nothing is sent off the Mac.

| Path | What |
|---|---|
| `~/Library/Application Support/Chirp/chirp.sqlite` | The database (`ChirpStore.defaultURL`) |
| `…/Chirp/Audio/` | Recordings and kept dictation or note audio (`.m4a`). `item.audioFile` is the file name |
| `…/Chirp/Documents/` | One folder per document: the original file, a saved web page, its images. `itemDocument.files` names it |
| `…/Chirp/Attachments/` | Files attached to recordings, and pictures of the screen taken during a recording |
| `…/Chirp/Recording in progress/` | The sound and lines of the recording being made |
| `…/Chirp/Recordings to finish/` | A recording that was not saved (a crash or a failed save). Recovered at the next launch |
| `…/Chirp/Recording audio not saved/` | Raw sound of a recording whose audio file could not be written |
| `…/Chirp/Models/` | The speech model file, and the optional sentence checker folder |
| `…/Chirp/Tools/` | The tool that downloads audio from links |
| `~/.cache/huggingface/hub/` | The language model and the search model (Hugging Face's cache) |
| `~/.cache/fluidaudio/Models/` | The reading voice |
| `~/Library/Application Support/FluidAudio/Models/` | Speaker labelling and voice detection |
| `~/Library/Logs/Chirp/chirp.log` | The log. Started again when it passes 1 MB |
| `~/Library/Preferences/<bundle id>.plist` | `UserDefaults` preferences |

A copy started with `--data-dir <folder>` keeps the database, `Audio`, `Documents` and the recording folders
in that folder instead. Models, tools and preferences are shared with the installed app. A copy started with
`--ui-testing` and no `--data-dir` keeps its database in memory and its audio in a temporary folder.

## What is stored, and what never is

Stored, because the user asked for it to be kept:

- The words of dictations, notes, meetings and documents, and their summaries.
- Audio, when the matching "keep audio" setting is on.
- For a recording: calendar event title, attendees and links; the call app; attached files and their text;
  the text read from the window in front while recording (used to get names and numbers right).
- Dictionary words, snippets, app styles, dismissed suggestions, counted single-word corrections.

Never stored:

- Text from password fields, sign-in and payment fields, or text that looks like a key or token
  (`Secrets`, `SignInField`).
- What the user types in other apps, except a sentence they choose to fix or rephrase while it is on screen.
- The text around a counted correction.
- Any of the user's words in the log.

## Export and deletion

- Each item can be exported from the Library as Markdown or plain text, and its audio as a file.
- A note can be exported as Markdown or text, or shared.
- A read-aloud document can be saved as an `.m4a` file.
- Export… on the Writing style page (its learned tab) saves the profile, dictionary, snippets, app styles
  and dismissed rules as one JSON file (`PersonalLanguage.export()`).
- There is no automatic backup. To back up, quit Chirp and copy `~/Library/Application Support/Chirp`.
- **Delete my library** (`DataReset.deleteLibrary`) deletes every item and folder, then the library's files.
  The dictionary, snippets, style, templates and settings stay.
- **Reset Chirp completely** (`DataReset.eraseEverything`) erases the whole database and removes downloaded
  models and tools. The next launch is a fresh install.
