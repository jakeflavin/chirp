# Contributing to Chirp

Thanks for helping. Bug reports, ideas, docs fixes and code are all welcome.

## Before you start

- **Bugs:** use **Help › Send Feedback…** in Chirp, or the [bug form](https://github.com/jakeflavin/chirp/issues/new?template=bug.yml).
- **Ideas and questions:** [Discussions](https://github.com/jakeflavin/chirp/discussions).
- **Larger changes:** open an issue or discussion first, so we can agree on the approach before you spend time on it.

Chirp is Mac only, English only, and runs everything on the user's Mac. Changes that need a server, an account or another platform won't be merged.

## Set up

You need a Mac with Apple Silicon, macOS 26 or later, Xcode 27, [Homebrew](https://brew.sh) and [Rust](https://rustup.rs).

```bash
git clone https://github.com/jakeflavin/chirp.git
cd chirp
Scripts/bootstrap.sh
```

Then follow [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md) to build, sign with your own team (optional) and run a test copy that keeps its data apart from your real Chirp.

## Making a change

1. Read [AGENTS.md](AGENTS.md). It has the rules for people and coding agents alike, and says which doc to read for each area.
2. Branch from `main`. Keep each pull request to one change.
3. Follow [Docs/CODING-STANDARDS.md](Docs/CODING-STANDARDS.md) and, for UI, [Docs/DESIGN.md](Docs/DESIGN.md).
4. Check it:
   - `cd Packages/ChirpCore && swift test`
   - build the app and try the change in a test copy
   - `Scripts/e2e.sh` with `ONLY=<area>` for the area you touched ([Docs/TESTING.md](Docs/TESTING.md))
5. Update the docs in the same pull request if behaviour, architecture, settings, permissions or network calls changed.
6. Open the pull request and fill in the template. CI runs the unit tests and an unsigned build.

## Commits

Short subject in the imperative ("Fix the perch flicker in full screen"), with a body that says why if it isn't obvious. Coding agents may add a `Co-Authored-By` line.

## Licence

By contributing, you agree your contribution is released under the [GPL-3.0](LICENSE), the same as the rest of Chirp.

## Conduct

Be kind and assume good intent. See the [Code of Conduct](CODE_OF_CONDUCT.md).
