# Security

## Reporting a problem

Please report security problems privately, not in a public issue.

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Describe the problem, the Chirp version (Chirp › About Chirp) and the steps to reproduce it.

You'll get a reply within a week. Fixes ship in the next release, and the advisory is published once people have had time to update.

## Supported versions

Only the latest stable release and the latest beta get fixes. Chirp updates itself, so most people are on the latest version.

## What counts

- Anything that sends your text, audio or files off your Mac.
- Anything that lets another app or website make Chirp act without you (for example through the `chirp://` link scheme).
- Downloads that could be swapped for something else (models, tools, updates).
- Ways to read Chirp's library or recordings without the user's permission.

## How Chirp is built to stay safe

- All speech, language and voice models run on your Mac. Nothing you write, say or record is sent anywhere. [Docs/PRIVACY.md](Docs/PRIVACY.md) lists every network call Chirp makes.
- Models run in separate helper processes, never in the app itself.
- Releases are signed with a Developer ID and notarized by Apple. Updates are signed with an EdDSA key and checked by Sparkle before they install.
- The `chirp://debug/` links only work when Chirp is started with the `--debug-hooks` flag, which the test scripts use. A normal launch ignores them.
