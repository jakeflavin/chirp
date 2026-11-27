# Changelog

All notable changes to Chirp. Versions follow [Semantic Versioning](https://semver.org). Betas are tagged `vX.Y.Z-beta.N`.

## [Unreleased]

## [0.3.0]

- **Notes:** New Note opens with the keyboard in the note and starts listening at once. Words appear as you pause, typing takes over, and the shortcut again or Escape saves it.
- **Icons:** a thinner line, and clearer drawings for Meeting, Rephrase, Read aloud, Save as a Snippet, Type again and Say it as.
- **Menu bar:** every command is in the menu bar, with File, Find and Go menus and Help › Keyboard Shortcuts.
- Onboarding asks before it downloads the speech model.
- Deleting a dictation or snippet asks first.
- Say it as opens in a popover on the word.
- Fixed: saved web pages could run their scripts when imported. They now load with scripts off and fetch nothing.
- Fixed: the search model stayed in memory after its features were switched off.
- Fixed: a second writing fix chosen while the first was still going in could fail or land in the wrong place.
- Fixed: Space and the arrow keys acted on the player while you typed in a field.
- Dictation writes "i.e." and "e.g." closed up.
- Removed: questions about a meeting, which no screen offered.
- Better VoiceOver labels, contrast and Reduce Motion behaviour across the app.

## [0.2.2]

- The download opens in a designed window that shows where to drag Chirp.

## [0.2.1]

- Fixed: turning off **Show Chirp in the menu bar** made Chirp quit.

## [0.2.0] — first public release

- **Dictate** into any app with a shortcut. Speech is turned into text on your Mac.
- **Record** meetings, calls and voice notes, with a live transcript and notes afterwards.
- **Write checks**: spelling and grammar underlines in other apps, plus Fix and Rephrase.
- **Read aloud** any text, page or document in a natural voice.
- **Summarize** pages, PDFs and emails.
- **Notes** with search by meaning.
- Updates from inside the app, with an opt-in beta channel.
