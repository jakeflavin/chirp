# Chirp design

How Chirp looks, moves and talks. Follow it for every change to the interface, whether you are a person
or a coding agent. When this file and the code disagree, fix one of them in the same change.

The shared pieces live in `App/Sources/Design/`:

| File | What it holds |
|---|---|
| `Theme.swift` | Colour tokens, type tokens, page layout, and the shared views (`Page`, `PageHeader`, `SectionHeading`, `HeadingLink`, `ItemRow`, `IconButton`, `ActButton`, `ChipLabel`, `Card`, `EmptyLine`, `SourceLine`, `ProgressBar`, `FlowLayout`, `Image.toolbarIcon`) |
| `Glass.swift` | Liquid Glass surfaces (`chirpGlass`, `chirpGlassCapsule`), fills on glass (`GlassFill`), shape motion (`GlassMotion`) |
| `Bird.swift` | The bird, drawn in code, with its moods |
| `Beta.swift` | The Beta flag, `BetaTag`, `BetaSidebarHeader` |
| `MarkdownText.swift` | Formatted Markdown for notes and summaries |

The perch has its own measurements in `PerchStyle` (`App/Sources/Perch/PerchViews.swift`).

Use these before writing a new value. If a view needs a size, colour or radius that is not here, either
the set is missing something (add it here and in code) or the job is not new (use what exists).

---

## 1. Principles

1. **Native Mac.** Use the Mac's own typeface, controls, menus, sheets, toolbars, keyboard behaviour and
   Liquid Glass. Do not draw a custom control where a system one does the job.
2. **Quick surfaces grow out of the perch.** Anything Chirp shows over other apps (a summary, the writing
   suggestions, a note, recording notes, a dropped file, a status) is part of the perch's one surface, or a
   bubble from its bird. Never open a floating window, card or panel of its own. The one exception is the
   suggestion card, which sits against the underlined word in another app.
3. **One thing at a time.** While Chirp is busy, the perch's actions give way to that one job, with a way
   out at its right end. A page shows one item. A row has at most one amber action.
4. **Quiet.** Words and icons in Ink or Quiet; colour only where it carries meaning; no decoration; help
   text only where a name is not enough.
5. **Light and dark.** Every colour has both values. Everything, floating surfaces included, follows the
   appearance chosen in Settings › General (Light, Dark, or the Mac's setting). Never force a surface dark.
6. **Every feature stays reachable.** A feature switched off in Settings › General is gone from the perch,
   the menu bar and the Library, and what it saved is kept. Nothing else is hidden.

### Beta builds

One build setting decides it: `CHIRP_CHANNEL: Beta` in `project.yml`. It sets the `BETA` compile
condition and picks the `AppIconBeta` icon set. Check it in code with `Beta.isOn`.

| Where | Beta build | Stable build |
|---|---|---|
| App icon | `AppIconBeta` | `AppIcon` |
| Sidebar top | `BetaSidebarHeader`: "Chirp", the tag, version and build | Nothing |
| Perch | `BetaTag(onGlass: true)` under the bird on the taller bar | Nothing |
| Menu bar popover | The tag beside the status | Nothing |
| Onboarding | The tag beside "Welcome to Chirp" | Nothing |
| Settings › General | Version with the tag | Version only |

Rules: use `BetaTag` for every marker (never a new badge); put every marker behind `Beta.isOn`; a stable
build shows no marker anywhere.

---

## 2. The perch

The perch is the bird on a glass bar at the bottom of the screen. It is how Chirp is used from any app.

### What it shows at rest

Settings › Perch › Show (`PerchPresence`):

| Setting | At rest |
|---|---|
| Full | The bird, the actions, the chevron |
| Present | The bird alone |
| Quiet | A faint wire only |
| Hidden | Nothing until Chirp is working |

Position: bottom left, centre or right; drag it by the bird to any edge. At a side edge it stands upright
and content opens beside the column. With "Tuck away in full screen" on, it slides under the edge in a
full-screen app and comes out when the pointer rests on that edge. Any Chirp shortcut brings a hidden or
tucked perch back.

### Bar states (`PerchBar`)

| State | What the bar holds |
|---|---|
| `wire` | The wire only |
| `bird` | The bird only |
| `actions` | The bird, a hairline, up to five actions, a hairline, the chevron |
| `dictating` | Level meter and clock |
| `working` | Working dots and a line ("Writing it down", "Part 2 of 5") |
| `meeting` | Recording light, "Recording", clock, Stop |
| `reading` | Playback controls |
| `preparing` | "Getting the voice ready" |

Busy states use exactly the resting bar's footprint (`PerchStyle.busySize`), so starting or ending a job
never changes the perch's size, corner or place.

### How it grows

1. **Pointed at.** After 0.3 s of rest the same bar grows taller (80 pt flat, 100 pt upright) and shows
   each action's short name and shortcut. It closes 0.1 s after the pointer leaves.
2. **Chevron.** Pressing it opens the extended area on the same glass with no tint: the extended actions,
   then "…" for one-off items (Save as a Snippet, the app's writing style, Library, Settings). Pressing it
   again closes it. Right-click adds Customize Perch….
3. **Showing something** (`PerchContent`): the surface rises out of the bar as one shape with a head row
   (title, grey detail, taller/shorter, close), a body, a foot row of next actions (the main one first, `esc`
   at the far end), then the bar with the action in use tinted. A handle pulls it taller; the height is
   remembered per kind.
4. **Saying something.** A status, an error or the call offer is a bubble from the bird. The perch never
   changes shape for it.

| Content | Opens for |
|---|---|
| `document` | A dropped or summarized document |
| `fixes` | The list of writing suggestions |
| `rephrase` | Fix, rephrase and the rest, on selected text |
| `sayItAs` | How a word just read aloud should sound |
| `notes` | A recording's finished notes |
| `meetingNotes` | Live transcript and own notes while recording |
| `note` | A note being typed or dictated |

### Sizes (`PerchStyle`)

| Measure | Value |
|---|---|
| Bar thickness (flat) / width (upright) | 46 |
| Taller bar | 80 flat, 100 upright |
| Round button on the bar | 34 |
| Word button | 26 high |
| Bird | 30 |
| Gap between neighbours | 2 |
| Hairline room | 11 (line plus 5 each side) |
| Corner once it holds content | 22 (alone, the bar is a capsule) |
| Content width | 420, up to 520 as it is pulled taller |
| Content body height | 210 by default, 96 least, up to 70% of the screen less 150 |
| Bubble | max width 300, line height 34, text 13, radius 17 (one line) or 16, 3 lines before "More" |

### Adding an action

1. Add a case to `PerchAction` (`Packages/ChirpCore/.../PerchArrangement.swift`) with `title` (full name,
   used in Customize Perch, menus and VoiceOver) and `shortTitle` (one word under the icon).
2. Tie it to a feature in `isOn(_:)`. An action whose feature is off is shown nowhere.
3. Give it a `PerchTool` in `PerchController.tool(_:)`: an icon from Chirp's set, its label, and its
   shortcut text if it has one.
4. Decide its place in `PerchArrangement.standard`. The bar holds five at most; new actions go in the
   extended area unless they are used many times a day.
5. If it shows something, it must open as `PerchContent` in the perch's one surface, never in a window.
6. If it runs a job, the job uses a busy state with a way out at the right end.
7. Use the same name everywhere: perch, menu bar popover, Customize Perch, Settings › Shortcuts.

---

## 3. Windows and other places

### Library window

One window (`LibraryWindow`, default 1160 × 740). Paper content, a floating glass sidebar, glass toolbar
groups.

- **Sidebar**: Home; **Library** (All, Meetings, Notes, Dictations, Documents); Folders; **Your language**
  (Dictionary, Snippets, Writing style); Settings at the foot. A heading with nothing under it is not shown.
  Arrow keys move between rows.
- **Toolbar**: app actions only: the sidebar button, Add, and Search last (⌘F). What acts on the open item
  sits in the item's header under its title, never in the toolbar.
- **Pages** start with `Page`/`PageHeader`: a 28 pt bold title and one grey line under it, in the same
  place on every page.
- **List pages**: a 300 pt list column and the open item on the right, titled at 20 semibold.
- **Item header**: view switch, Copy, Export, Read aloud (or Summarize), and … for Pin, Move to Folder,
  Attach, Delete. When the window is narrow, buttons go icon-only with tooltips, then fold into ….
- **Empty page**: the bird, one line (`EmptyLine`), and the one button that fills the page.

### Home

A welcome line written by rule, with the bird beside it and This week under it; the start bar (glass
capsule); Pinned and folders as tiles; then sections that show only when they have something: In progress,
Coming up, Carry on, Captured today, one tip. Each section is its own view in `HomeSections.swift` and can
be removed on its own. With nothing to show, the bird sits in the middle of the page.

### Settings

A page of the Library window, and the same page in its own window from the menu bar. Organised **by
feature**, one tab each, shown as chips under the header:

General · Perch · Dictation · Meetings · Notes · Reading · Writing · Models · Shortcuts

- General holds Features (switch each feature on or off), Where Chirp shows, light or dark, permissions,
  help, About and the danger zone.
- A feature's tab holds only that feature's settings. When the feature is off, its tab stays and says so.
- Every setting's name is listed in `SettingsTab.settings` so the search field finds it. Add new ones there.
- Groups use `SettingsSection` (13 semibold heading). A grey line under a setting's name only when the name
  is not enough.
- Changes apply at once. No Save or Apply buttons.

### Menu bar extra and the Dock

- The menu bar icon is the bird as a template image (`MenuBarIcon`), so the menu bar picks its colour. It
  shows state: faded while working, a small mic while dictating, a small speaker while reading, "!" when
  something needs a look. **Red is the only colour it ever shows, and only while recording.**
- The popover is one sheet of glass laid out on the perch's spacing: status row, tiles (Dictate, Note, Read,
  Fix, Summarize), Record a meeting, Recent, up to four settings for what is being done (the feature
  switches at rest), "All settings…" last, then Open Library and Quit. It works with the keyboard.
- Settings › General › "Show Chirp in the Dock" (`DockPresence`). With the Dock icon off, Chirp lives in
  the menu bar and the perch, and the menu bar icon is forced on so Chirp is always reachable.

### Onboarding

A first-run window, 600 wide, one step per thing, each using the real control: features, dictation,
shortcuts, permissions, models, language, writing, notes, meetings, reading. It sets the app up (choices,
permissions, models, first data), so the app never opens blank. It can be opened again from Settings ›
General and resets nothing.

---

## 4. Colour

Colours come from the bird (amber body, clay beak) and the page it sits on (warm paper, navy ink). Every
colour has a light and a dark value in `App/Resources/Assets.xcassets` and a name in `Theme.swift`.

### The set

| Name | Code | Asset | Light | Dark | Its job |
|---|---|---|---|---|---|
| Paper | `Color.paper` | `Paper` | `#FBF8F2` | `#17191F` | The window |
| Card | `Color.card` | `Card` | `#FFFFFF` | `#20232B` | A raised surface inside a window |
| Float | `Color.float` | `Float` | `#FFFFFF` | `#272A33` | Anything over other apps: the perch's solid surface, the suggestion card. A step lighter than Card in the dark so it lifts off a dark window |
| Ink | `Color.ink` | `Ink` | `#1F2430` | `#ECE8E1` | Words you read. Lines and tints are Ink at low strength |
| Quiet | `Color.quiet` | `Quiet` | `#6B7080` | `#9BA0AE` | Words that support: captions, times, counts, reasons |
| Clay (accent) | `Color.accentColor` | `AccentColor` | `#D9621F` | `#F28A45` | The system accent: switches, prominent system buttons, selection, focus rings, links |
| Amber | `Color.amber` (`.birdBody`) | `BirdBody` | `#F6B93B` | `#F6B93B` | The bird, and what it offers or is doing: the action in use, the main action of a row, the suggested fix, counts, progress |
| On Amber | `Color.onAmber` | `OnAmber` | `#2B2110` | `#2B2110` | Words and icons on Amber |
| Robin | `Color.spelling` | `Spelling` | `#C23A4B` | `#F27A8A` | A mistake (spelling). Also the recording light and anything that deletes |
| Jay | `Color.grammar` | `Grammar` | `#2B77A8` | `#74B9E6` | Grammar. Also the other people in a transcript |
| Moss | `Color.style` | `Style` | `#3F7F45` | `#8ACB8F` | Style suggestions. Also "allowed" and "done" |
| Caution | `Color.caution` | `Caution` | `#B26A00` | `#F6B93B` | Needs attention, nothing broken: a warning line, a missing permission |
| Bird belly | `Color("BirdBelly")` | `BirdBelly` | `#FCE7B0` | `#FBE2A0` | The bird only |
| Bird beak | `Color("BirdBeak")` | `BirdBeak` | `#E2702A` | `#EE8440` | The bird only |

### Tints (Ink at low strength)

| Use | Value |
|---|---|
| Line between rows (`PageLayout.line`) | Ink 12% |
| Hover under a row (`PageLayout.hover`) | Ink 5% |
| Picked row (`PageLayout.selected`) | Ink 9% |
| Card edge | Ink 7% |
| Quiet chip / chip selected | Ink 7% / 14% |
| Button hover | Ink 8% |
| Perch on a solid surface: line, hover, chip | Ink 13%, 7%, 11% |

### Why these go together

- Warm and one cool. Paper, Clay, Amber and Robin are warm; Ink and Jay are the cool side. Jay is opposite
  Clay on the colour wheel, so grammar underlines stand apart from anything you can click.
- Robin is a rose red, not an orange red, so a mistake never looks like the accent.
- The three meaning colours are equally strong. In light mode each reads as text on white (contrast 4.5 or
  more); in dark mode each reads on Float.
- Amber does not change with the mode, because the bird does not.

### Rules

1. **No system colours and no one-off values.** No `.red`, `.orange`, `.blue`, `.green`, `.secondary`, no
   `Color(red:green:blue:)`. Use a token. If none fits, the set is wrong or the job is not new.
2. **Not a rainbow.** The palette is the subject's: paper, ink, the bird. Meaning colours are for meaning
   (an underline, a dot, a recording light), never decoration and never button colours, except Robin on a
   button that deletes.
3. **One accent per surface.** On the perch and its cards, the thing to click is Amber, because the bird is
   offering it; Clay does not appear there. In a window, Clay is the system accent on system controls, and
   Amber marks Chirp's own one main action of a row or step and the action in use. Never two amber actions
   in one row.
4. **Text is Ink or Quiet.** Coloured text only for a word that is itself the meaning (a speaker's name, a
   warning line).
5. **Tints come from Ink**, so they work in both modes without values of their own.
6. **Floating surfaces follow light and dark.** The perch is Liquid Glass with Float laid over it; with
   Reduce Transparency it is solid Float. Words and icons on glass use the system's own ink levels
   (`Color.primary` at set strengths, see section 6); its buttons are still Amber.
7. **The bird is on anything Chirp shows over other apps** (the perch, the suggestion card, the call
   offer), so it is always clear the surface is Chirp's.
8. **Colour is never the only signal.** An underline's colour has a matching dot and a sentence in its card;
   the recording light has the word "Recording" beside it; each underline kind also has its own line style
   (spelling wavy, grammar solid, style dashed, snippet cue dotted).

---

## 5. Type

One typeface: the Mac's own (`Font.system`). **No serif anywhere. No rounded design.**

### Scale

| Role | Token | Size and weight |
|---|---|---|
| Page title | `.pageTitle` | 28 bold, tracking -0.5 |
| Onboarding step title | | 24 bold, tracking -0.4 |
| Open item title (right of a list) | `.detailTitle` | 20 semibold |
| Document text in the reader | `.reading` | 16 |
| Sheet title | | 15 semibold |
| Section heading | `.sectionTitle` | 13 semibold, Ink |
| Row title, body, perch content title | | 13 (row titles medium) |
| Buttons and chips (`ActButton`, `ChipLabel`) | | 12.5 (semibold when primary or selected) |
| Row meta, line under a name, foot row | `.rowMeta` | 12, Quiet |
| Sidebar and group headings | | 11 semibold, Quiet |
| Perch tile names | | 10.5, Quiet |
| Beta tag | | 10 semibold |

Numbers that change in place (clocks, counts, percentages) use `.monospacedDigit()`.

### Hierarchy rules

- Every page starts the same: the 28 pt title and one grey line under it, in the same place.
- An item is two lines: its name, then what it is underneath (`ItemRow`). Never a description floated to
  the right.
- The right edge of a row holds only things to press, or one number.
- A section heading is 13 semibold in full Ink, its count after it in Quiet, at most one link at the far
  right (`SectionHeading`, `HeadingLink`).

### Where small text goes

Each kind of small text has one place:

| Small text | Its place |
|---|---|
| What an item is (kind, time, length) | The line under its name |
| A count | After its section heading, in Quiet |
| Where something came from | `SourceLine`: a small grey line with the kind's icon, above what it produced |
| Help for a setting | Under the setting's name, only when the name is not enough |
| A shortcut | On the perch's taller bar, in Settings › Shortcuts, and in the popover. Written "right ⌥ N" where there is room, "⌥N" on perch tiles and popover rows |
| Help for an icon button | Its tooltip (`.help`) and VoiceOver label, not a line on screen |

---

## 6. Layout, shape, glass

### Spacing

| Measure | Value |
|---|---|
| Page gutter (`PageLayout.gutter`) | 44 from the page's left edge to every title, heading and row |
| List column (`PageLayout.listWidth`) | 300 |
| Two-line row least height (`PageLayout.rowHeight`) | 52 |
| Row padding | 10 each side; the hover tint reaches 10 past the text so the text stays on the gutter |
| Section heading | 21 above, 5 below |
| Page header | 6 above the title, 3 between title and grey line |
| Card padding | 16 |
| Icon beside text | 6 to 12 |
| Sidebar | 10 each side, 46 at the top (clear of the window controls) |
| Narrow window | Below 900 wide the layout changes; smallest window 760 × 520 |

### Corner radii

Use one of these. All are `.continuous` unless the shape is a capsule or circle.

| Radius | Used for |
|---|---|
| Capsule | Buttons with words, chips, tags, the bare perch bar, the start bar, search field |
| Circle | Icon buttons |
| 4 | Small covers |
| 5–6 | Key caps |
| 7 | Buttons inside the suggestion card |
| 8 | Popover controls |
| 9 | Row hover and selection |
| 12 | Cards and grouped forms |
| 14 | Suggestion card |
| 16–17 | Status bubble |
| 22 | The perch once it holds anything |

### Liquid Glass

Glass (`Glass.swift`) is for controls and navigation only: the perch, the menu bar popover, the sidebar,
toolbar groups, the start bar, and a recording's bottom bar. Content stays on Paper.

- Use `chirpGlass(in:)` or `chirpGlassCapsule()`. Never call `glassEffect` directly.
- **Never glass on glass.** What sits on glass uses a fill:

| `GlassFill` | Value |
|---|---|
| `hover` (and a quiet chip) | `Color.primary` 8% |
| `row` (chosen row) | `Color.primary` 7% |
| `line` | `Color.primary` 12% |
| `track` | `Color.primary` 18% |

- On the perch, words use `PerchStyle.ink` (`Color.primary`) and `PerchStyle.quiet` (`Color.primary` 62%,
  stronger than the system's second level, which washes out on glass).
- A surface that holds words to read lays Float over the glass (`wash`; the perch uses 0.62) so text stays
  readable over a busy page in light and dark.
- Tint only the action in use.
- Reduce Transparency: a solid Float surface with an Ink 16% edge and a shadow. Increase Contrast: a firm
  Ink 55% edge.

### Shadows

Glass brings its own. Only solid floating surfaces add one:

| Surface | Shadow |
|---|---|
| Solid perch (Reduce Transparency) | black 22%, radius 12, y 5 |
| Solid floating card (`PerchStyle.shadow`) | black 26% |
| A small cover | black 15–30%, radius 1.5–3 |

Windows content (cards, rows) has no shadow; it uses an Ink edge.

---

## 7. Icons

Chirp has its own icon set: round line, one weight, round caps and joins. **Never use SF Symbols**, and no
bird or mascot shapes inside icons (the bird is only the bird).

### Using an icon

| Where | How |
|---|---|
| SwiftUI view | `Image("chirp.copy")`; it follows the font size and weight like a system symbol |
| Label | `Label("Copy", image: "chirp.copy")` |
| Window toolbar | `Image.toolbarIcon("chirp.search")`. SwiftUI draws a named custom symbol blank in the toolbar, so the toolbar must use this |
| AppKit | `NSImage(named: "chirp.copy")` |

Size icons with `.font(.system(size:weight:))`, usually 11–14 pt. Every icon-only button has a VoiceOver
label and a tooltip.

### Style

- 24 pt grid with a 2 pt margin; a 20 pt circle and square as keylines.
- One thin line, about 1.1 pt at 16 pt (1.0 pt at the perch's 14.5 pt), round caps and round joins. A thicker line blurs at perch size.
- Pages, cards and bubbles have rounded corners; sound and speech are circle arcs.
- Media controls (play, pause, stop, back, forward) and set states (`pinFill`, `bookmarkFill`,
  `checkCircle`) are filled; everything else is line.
- A slashed state (`unpin`) cuts a gap around the slash.

### Adding an icon

1. Draw it on the same 24 pt grid with the same thin round line, next to two or three existing icons to
   check weight and size.
2. Open the SF Symbols app, export any symbol's template (File › Export Template, template version 3.0),
   and put your drawing in the Regular-M, Medium-M, Semibold-M and Bold-M slots. Convert strokes to filled
   outlines. Keep it monochrome.
3. Validate the template in the SF Symbols app.
4. Add it to `App/Resources/Assets.xcassets/Icons/` as `chirp.<name>.symbolset`, holding `chirp.<name>.svg`
   and a `Contents.json` that names it (copy an existing one).
5. Name it by what it does, in lower camel case. Add a row to the table below.
6. Before it ships, check that people can name it: show it unlabelled among the perch icons, at perch size, to a few people who have not seen it.

### The set

| Name | Meaning |
|---|---|
| `chirp.add` | Add |
| `chirp.addWord` | Add to Dictionary |
| `chirp.again` | Again, redo |
| `chirp.all` | All (every saved item) |
| `chirp.attach` | Attach |
| `chirp.back` | Back a sentence (filled) |
| `chirp.back15` | Back 15 seconds |
| `chirp.bookmarkFill` | Bookmark, set (filled) |
| `chirp.calendar` | Calendar |
| `chirp.camera` | Screenshot, capture the front window |
| `chirp.check` | Done |
| `chirp.checkCircle` | Allowed (filled) |
| `chirp.chevron` | The perch's chevron, flat |
| `chirp.clear` | Clear |
| `chirp.close` | Close |
| `chirp.collapse` | Make shorter |
| `chirp.copy` | Copy |
| `chirp.dictate` | Dictate |
| `chirp.dictionary` | Dictionary |
| `chirp.disclose` | Show more; the perch's chevron, upright |
| `chirp.documents` | Documents |
| `chirp.drafts` | Drafts (test copy only) |
| `chirp.drop` | Drop a file |
| `chirp.edit` | Edit |
| `chirp.expand` | Make taller |
| `chirp.export` | Export |
| `chirp.file` | File |
| `chirp.findText` | Find in text |
| `chirp.fix` | Fix writing |
| `chirp.folder` | Folder |
| `chirp.forward` | Forward a sentence (filled) |
| `chirp.fwd15` | Forward 15 seconds |
| `chirp.getOriginal` | Get the original |
| `chirp.hide` | Stop showing |
| `chirp.home` | Home |
| `chirp.library` | Library |
| `chirp.link` | Link |
| `chirp.meeting` | Meeting (two people and a recording dot) |
| `chirp.mic` | Microphone |
| `chirp.more` | More (…) |
| `chirp.note` | Note |
| `chirp.open` | Open |
| `chirp.options` | Options |
| `chirp.pause` | Pause (filled) |
| `chirp.picture` | Picture |
| `chirp.pin` | Pin |
| `chirp.pinFill` | Pinned (filled) |
| `chirp.play` | Play (filled) |
| `chirp.pointer` | Accessibility permission |
| `chirp.power` | Turn off |
| `chirp.read` | Read aloud (a page with sound coming off it) |
| `chirp.record` | Record |
| `chirp.rephrase` | Rephrase (a pencil inside turning arrows) |
| `chirp.ring` | Not yet |
| `chirp.sayAs` | Say it as (a letter between phonetic slashes) |
| `chirp.search` | Search |
| `chirp.settings` | Settings |
| `chirp.share` | Share |
| `chirp.sidebar` | Show or hide the sidebar |
| `chirp.snippetAdd` | Save as a Snippet (scissors and a plus) |
| `chirp.snippets` | Snippets |
| `chirp.stop` | Stop (filled) |
| `chirp.style` | Writing style |
| `chirp.summarize` | Summarize |
| `chirp.textInPicture` | Text in a picture |
| `chirp.trash` | Delete |
| `chirp.typeAgain` | Type the last dictation again (a clipboard) |
| `chirp.unpin` | Unpin |
| `chirp.voiceNote` | Voice note |
| `chirp.warning` | Warning |
| `chirp.write` | Write |

The same action uses the same icon everywhere (perch, popover, sidebar, headers, menus).

---

## 8. Motion

Motion shows a change of shape or state. Nothing moves for decoration.

| What | Animation |
|---|---|
| A glass surface growing (`GlassMotion.grow`) | spring, response 0.42, damping 0.8 |
| A glass surface shrinking (`GlassMotion.shrink`) | spring, response 0.45, damping 1.0 (no bounce) |
| Content inside a changing shape (`GlassMotion.content`) | ease in-out, 0.35 s cross-fade |
| Small things: a highlight, a button appearing (`PerchStyle.quick`) | spring, response 0.24, damping 0.86 |
| A perch button pressed | spring, response 0.18, damping 0.7 |
| Pointer highlight on the perch | ease out, 0.12 s |
| Bar content swapping (busy states) | blur replace with fade |
| Status bubble appearing | scale from 0.9 at its tail, with fade |
| Level meter | linear, 0.1 s |
| Recording light | a ring that breathes out over 1.6 s, repeating |
| Working dots | one step every 0.35 s |
| The bird | blinks every 3.5–6 s when idle; moves with its mood and the audio level |
| Sidebar show and hide, narrow layout | ease in-out, 0.2 s |
| Keyboard scroll in a list | ease out, 0.15 s |
| Perch opening on pointing | after 0.3 s of rest; closes 0.1 s after the pointer leaves |

### Reduce Motion

Read `@Environment(\.accessibilityReduceMotion)` in any view that animates, and pass it on:

- Shape changes use `GlassMotion.shape(growing:reduceMotion:)`, which gives a 0.2 s fade
  (`GlassMotion.reduced`).
- Scale, blur and slide transitions become `.opacity`.
- Repeating motion stops: the recording light holds still, the working dots stop, the bird does not blink
  or bob.

Never hard-code `reduceMotion: false`.

---

## 9. Copy

User-facing text is plain and short.

- Say what happened or what to do, in the fewest words. Sentence case. No exclamation marks.
- No quips, puns, metaphors or bird jokes. The bird is a picture, not a voice. ("Chirp is listening" is a
  status, not a character.)
- No helper text by default. Add a line only when the name is not enough.
- Name things the same everywhere. An action has one full name (VoiceOver, menus, Customize Perch) and at
  most one short name (under its icon).
- Errors say what failed and, if there is one, what to do next. Never blame the user.
- Empty states: one line saying what goes here, and the action that fills it.
- Status lines name the job and its progress: "Part 2 of 5", not "Transcribing · part 2 of 5".

| Do (from the app) | Don't |
|---|---|
| No meetings yet. | Your meetings will live here once you start recording! |
| Copied | Copied to your clipboard successfully! |
| Select some text, or click into what you want summarized | Oops, there's nothing for me to summarize. |
| Chirp could not transcribe interview.m4a | Something went wrong. |
| That is short enough to read as it is | Too short, Chirp's beak can't chew that one. |
| Writing it down | Working our magic… |
| Hold a key and speak. The words are typed where your cursor is. | Your voice, perfectly captured, anywhere you type. |
| Changes apply straight away | Don't worry, everything is saved automatically for you! |

---

## 10. Accessibility

- **Labels.** Every control has a VoiceOver label. Icon-only buttons take the action's full name
  (`IconButton(symbol:label:)` sets both label and tooltip). Decorative icons and the bird beside text are
  `.accessibilityHidden(true)`. The bird elsewhere says its mood ("Chirp is listening").
- **Headings.** Page titles, section headings and sheet titles have `.isHeader`.
- **Hints** say what happens, briefly: "Opens the folder", "Drag to make this taller or shorter",
  "Shortcut ⌥N".
- **Disabled over callout.** A control that cannot act now is disabled and its hint says why ("A recording
  is already under way", "Underlines are off in Settings, under Writing"). Never let it be clicked into an
  error message. Do not hide it either.
- **State.** Selected rows and tabs add `.isSelected`; toggles report on and off; the chevron reports
  "Open".
- **Contrast.** Ink and Quiet on Paper, Card and Float, and each meaning colour as text, meet 4.5:1. With
  Increase Contrast, glass gets a firm edge and on-glass inks get stronger.
- **Transparency.** With Reduce Transparency every glass surface is solid Float.
- **Motion.** See section 8.
- **Colour.** Never the only signal (section 4, rule 8).
- **Keyboard.** Everything works without a pointer:
  - Escape closes what the perch is showing, and cancels dictation.
  - Arrow keys move through the sidebar, lists and Home's rows; the menu bar popover is keyboard driven.
  - ⌘F searches the Library.
  - Chirp's global shortcuts are right ⌥ plus a letter, hold right ⌥ to dictate, ⌥Space hands-free,
    ⌥⇥ fixes the sentence at the cursor. All can be changed in Settings › Shortcuts.
- **Focus.** Panels over other apps never take keyboard focus unless the user is typing in them (a note),
  so typing continues in the user's app.
